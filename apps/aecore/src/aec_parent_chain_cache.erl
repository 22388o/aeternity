%%% -*- erlang-indent-level:4; indent-tabs-mode: nil -*-
%%%-------------------------------------------------------------------
%%% @copyright (C) 2022, Aeternity
%%% @doc
%%% Manage interaction with hyperchain parent chain
%%% @end
%%%-------------------------------------------------------------------

-module(aec_parent_chain_cache).

%% Functionality:
%% - cache the view of the parent chain's blocks. The `aec_parent_connector`
%%   reports any new blocks and they are stored in a cache.
%%   `aec_parent_connector` is also used for fetching blocks as we go along
%% - keeps track of current child chain top and fetches releated blocks. There
%%   are two strategies to be followed:
%%   - the node is syncing blocks from the past. In this case the cache is
%%     loading the lowest required parent chain block and then starts syncing
%%   upwards till it reaches the top
%%   - the node is fully synced and we are waiting for notifications from the
%%     parent chain nodes for top changes
%% - provides parent chain blocks to the consensus module on demand. If it
%%   asks for an older block, it is being fetched as well. This would take some
%%   more time as a couple of blocks are being queried
%% - cleans up older states
%% - is fork aware
-behaviour(gen_server).

%%%=============================================================================
%%% Exports and Definitions
%%%=============================================================================

%% External API
-export([start_link/2, stop/0]).

%% used in tests
-export([start_link/3]).

%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
            terminate/2, code_change/3]).

-export([post_block/1,
         get_block_by_height/1]).

-export([get_state/0]).

-define(SERVER, ?MODULE).
-define(FOLLOW_PC_TOP, follow_parent_chain_top).
-define(FOLLOW_CHILD_TOP, sync_child_chain).

-type strategy() :: ?FOLLOW_CHILD_TOP | ?FOLLOW_PC_TOP.


-record(state,
    {
        child_top_height                    :: non_neg_integer(),
        child_start_height                  :: non_neg_integer(),
        pc_confirmations                          :: non_neg_integer(),
        max_size                            :: non_neg_integer(),
        blocks          = #{}               :: #{non_neg_integer() => aec_parent_chain_block:block()},
        top_height      = 0                 :: non_neg_integer(),
        strategy        = ?FOLLOW_CHILD_TOP :: strategy()
    }).
-type state() :: #state{}.



%%%=============================================================================
%%% API
%%%=============================================================================
%% Start the parent chain cache process
-spec start_link(non_neg_integer(), non_neg_integer()) ->
    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason::any()}.
start_link(Height, Size) ->
    Args = [Height, Size],
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

-spec start_link(non_neg_integer(), non_neg_integer(), strategy()) ->
    {ok, pid()} | {error, {already_started, pid()}} | {error, Reason::any()}.
start_link(Height, Size, Strategy) ->
    Args = [Height, Size, Strategy],
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).


stop() ->
    gen_server:stop(?SERVER).

-spec post_block(aec_parent_chain_block:block()) -> ok.
post_block(Block) ->
    gen_server:cast(?SERVER, {post_block, Block}).

-spec get_block_by_height(non_neg_integer()) -> {ok, aec_parent_chain_block:block()}
                                              | {error, not_in_cache}.
get_block_by_height(Height) ->
    gen_server:call(?SERVER, {get_block_by_height, Height}).

-spec get_state() -> {ok, map()}.
get_state() ->
    gen_server:call(?SERVER, get_state).



%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

-spec init([any()]) -> {ok, #state{}}.
init([StartHeight, Size]) ->
    init([StartHeight, Size, ?FOLLOW_CHILD_TOP]);
init([StartHeight, Size, Strategy]) ->
    aec_events:subscribe(top_changed),
    ChildHeight = aec_chain:top_height(),
    true = is_integer(ChildHeight),
    self() ! initialize_cache,
    {ok, #state{child_start_height  = StartHeight,
                child_top_height    = ChildHeight,
                pc_confirmations    = 1, %% TODO: make this configurable
                strategy            = Strategy,
                max_size            = Size,
                blocks              = #{}}}.

-spec handle_call(any(), any(), state()) -> {reply, any(), state()}.
handle_call({get_block_by_height, Height}, _From,
            #state{pc_confirmations = Confirmations,
                   top_height = TopHeight } = State) ->
    Reply = 
        case get_block(Height, State) of
            {error, _} = Err -> Err;
            {ok, Block} when Height > TopHeight - Confirmations ->
                {error, {not_enough_confirmations, Block}};
            {ok, _Block} = OK -> OK
        end,
    {reply, Reply, State};
handle_call(get_state, _From, State) ->
    Reply = {ok, state_to_map(State)},
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

-spec handle_cast(any(), state()) -> {noreply, state()}.
handle_cast({post_block, Block}, #state{top_height = TopHeight,
                                        max_size = MaxSize } = State0) ->
    State = post_block(Block, State0),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(any(), state()) -> {noreply, state()}.
handle_info(check_parent, #state{ } = State) ->
    {noreply, State#state{}};
handle_info(initialize_cache, #state{strategy = ?FOLLOW_PC_TOP} = State) ->
    {noreply, State};
handle_info(initialize_cache, State) ->
    TargetHeight = target_parent_height(State),
    case aec_parent_connector:fetch_block_by_height(TargetHeight) of
        {ok, B} ->
            {noreply, post_block(B, State)};
        {error, not_found} ->
            lager:debug("Waiting for block ~p to be mined on the parent chain", [TargetHeight]),
            timer:send_after(1000, initialize_cache),
            {noreply, State};
        {error, no_parent_chain_agreement} ->
            lager:warning("Failed to initialize cache for height ~p", [TargetHeight]),
            timer:send_after(1000, initialize_cache),
            {noreply, State}
    end;
handle_info({gproc_ps_event, top_changed, #{info := #{block_type := key,
                                                      height := Height}}},
            State) ->
    %% TODO: post a commitment
    {noreply, State#state{child_top_height = Height}};
handle_info({gproc_ps_event, top_changed, _}, State) ->
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

-spec terminate(any(), state()) -> ok.
terminate(_Reason, _State) ->
    ok.

-spec code_change(any(), state(), any()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec insert_block(aec_parent_chain_block:block(), state()) -> state().
insert_block(Block, #state{blocks = Blocks} = State) ->
    Height = aec_parent_chain_block:height(Block),
    State#state{blocks = maps:put(Height, Block, Blocks)}.

-spec get_block(non_neg_integer(), state()) -> {ok, aec_parent_chain_block:block()} | {error, not_in_cache}.
get_block(Height, #state{blocks = Blocks}) ->
    case maps:find(Height, Blocks) of
        {ok, _Block} = OK -> OK;
        error ->
            %% TODO: fetch the block
            {error, not_in_cache}
    end.
    
-spec delete_block(non_neg_integer(), state()) -> state().
delete_block(Height, #state{blocks = Blocks} = State) ->
    State#state{blocks = maps:remove(Height, Blocks)}.

state_to_map(#state{child_start_height = StartHeight,
                    child_top_height   = ChildHeight,
                    pc_confirmations   = Confirmations,
                    max_size     = MaxSize,
                    blocks       = Blocks, 
                    top_height   = TopHeight}) ->
    #{  child_start_height => StartHeight,
        child_top_height   => ChildHeight,
        pc_confirmations   => Confirmations,
        max_size     => MaxSize,
        blocks       => Blocks, 
        top_height   => TopHeight}.

target_parent_height(#state{child_start_height    = StartHeight,
                            child_top_height      = ChildHeight}) ->
    ChildHeight + StartHeight.

post_block(Block, #state{top_height = TopHeight,
                         max_size = MaxSize,
                         strategy = Strategy } = State0) ->
    TargetHeight = target_parent_height(State0),
    BlockHeight = aec_parent_chain_block:height(Block),
    case Strategy =:= ?FOLLOW_CHILD_TOP andalso BlockHeight > TargetHeight + MaxSize of
        true ->
            %% we are syncing and this is a new top block that is too far away
            %% from the future; we ignore it
            State0;
        false ->
            %% the block received might be the top one or a previous one; we try GCing
            %% older blocks according to the top block only;
            %% if the previous block is missing, fetch it (if above the GC height)
            GCHeight = max(TopHeight - MaxSize, -1),
            State1 =
                case BlockHeight > GCHeight of
                    true ->
                        case BlockHeight > TopHeight + MaxSize of
                            true -> 
                                %% we received a block far from the future, so we have
                                %% to GC all blocks
                                insert_block(Block, State0#state{blocks = #{}});
                            false ->
                                insert_block(Block, State0)
                        end;
                    false -> State0
                end,
            TryGCHeight = BlockHeight - MaxSize,
            State2 =
                case TryGCHeight >= 0 of
                    true ->
                        delete_block(TryGCHeight, State1);
                    false -> State1
                end,
            State3 = State2#state{top_height = max(TopHeight, BlockHeight)},
            maybe_fetch_previous_block(BlockHeight, State3),
            maybe_fetch_next_block(BlockHeight, State3),
            State3
            
    end.

maybe_fetch_previous_block(BlockHeight, #state{ strategy = _AnyStrategy,
                                                top_height = TopHeight,
                                                max_size = MaxSize
                                          } = State) ->
    GCHeight = max(TopHeight - MaxSize, - 1),
    PrevHeight = BlockHeight - 1,
    case PrevHeight > GCHeight of
        true ->
            %% check if the previous block is missing
            case get_block(PrevHeight, State) of
                {ok, _} -> pass;
                {error, _} -> %% missing block detected
                    lager:debug("Missing block with height ~p detected, requesting it", [PrevHeight]),
                    aec_parent_connector:request_block_by_height(PrevHeight)
            end;
        false ->
            pass
    end.

maybe_fetch_next_block(BlockHeight, #state{strategy = ?FOLLOW_PC_TOP} = State) ->
    pass;
maybe_fetch_next_block(BlockHeight,
                       #state{strategy = ?FOLLOW_CHILD_TOP,
                              max_size = MaxSize } = State) ->
    TargetHeight = target_parent_height(State),
    MaxBlockToRequest = TargetHeight + MaxSize,
    NextHeight = BlockHeight + 1,
    case MaxBlockToRequest > BlockHeight andalso NextHeight < MaxBlockToRequest of
        true ->
            case get_block(NextHeight, State) of
                {ok, _} -> pass;
                {error, not_in_cache} ->
                    lager:debug("Populating the cache forward, requesting block with height ~p",
                                [NextHeight]),
                    aec_parent_connector:request_block_by_height(NextHeight)
            end;
        _ -> %% cache is already full
            pass
    end.

