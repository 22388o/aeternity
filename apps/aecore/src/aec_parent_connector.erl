%%% -*- erlang-indent-level:4; indent-tabs-mode: nil -*-
%%%-------------------------------------------------------------------
%%% @copyright (C) 2018, Aeternity Anstalt
%%% @doc
%%% Manage interaction with hyperchain parent chain
%%% @end
%%%-------------------------------------------------------------------

-module(aec_parent_connector).

%% Functionality:
%% - at intervals check parent chain to understand when new top block is
%%   available.
%% - New top block from parent chain should include commitment transactions
%%   on the parent chain.
%% - Call consensus smart contract
%% 
-behaviour(gen_server).

%%%=============================================================================
%%% Exports and Definitions
%%%=============================================================================

%% External API
-export([start_link/0, start_link/3, stop/0]).

%% Use in test only
-export([trigger_fetch/0]).

%% Callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
            terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(SEED_BYTES, 16).

%% top's state
-record(top,
    {
        hash = <<>> :: binary(),
        height = 0 :: non_neg_integer(),
        prev_hash = <<>> :: binary()
    }).
-type top() :: #top{}.

%% Loop state
-record(state,
    {
        parent_conn_mod = aehttpc_btc,
        fetch_interval = 10000, % Interval for parent top change checks
        parent_hosts = [],
        parent_top :: top(),
        rpc_seed = crypto:strong_rand_bytes(?SEED_BYTES) % BTC Api only
    }).
-type state() :: #state{}.


%%%=============================================================================
%%% API
%%%=============================================================================
-spec start_link() -> {ok, pid()} | {error, {already_started, pid()}} | {error, Reason::any()}.
start_link() ->
    FetchInterval = 10000,
    ParentHosts = [#{host => <<"127.0.0.1">>,
                    port => 3013,
                    user => "test",
                    password => "Pass"
                    }],
    ParentConnMod = aehttpc_aeternity,
    start_link(ParentConnMod, FetchInterval, ParentHosts).

%% Start the parent connector process
%% ParentConnMod :: atom() - module name of the http client module aehttpc_btc | aehttpc_aeternity
%% FetchInterval :: integer() | on_demand - millisecs between parent chain checks or when asked (useful for test)
%% ParentHosts :: [#{host => Host, port => Port, user => User, password => Pass}]
-spec start_link(atom(), integer() | on_demand, [map()]) -> {ok, pid()} | {error, {already_started, pid()}} | {error, Reason::any()}.
start_link(ParentConnMod, FetchInterval, ParentHosts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [ParentConnMod, FetchInterval, ParentHosts], []).

stop() ->
    gen_server:stop(?MODULE).

trigger_fetch() ->
    gen_server:call(?SERVER, trigger_fetch).

%%%=============================================================================
%%% Gen Server Callbacks
%%%=============================================================================

-spec init([any()]) -> {ok, #state{}}.
init([ParentConnMod, FetchInterval, ParentHosts]) ->
    if is_integer(FetchInterval) ->
        erlang:send_after(FetchInterval, self(), check_parent);
        true -> ok
    end,
    {ok, #state{parent_conn_mod = ParentConnMod,
                fetch_interval = FetchInterval,
                parent_hosts = ParentHosts}}.

-spec handle_call(any(), any(), state()) -> {reply, any(), state()}.
handle_call(trigger_fetch, _From, State) ->
    self() ! check_parent,
    Reply = ok,
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

-spec handle_cast(any(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(any(), state()) -> {noreply, state()}.
handle_info(check_parent, #state{parent_hosts = ParentNodes,
                                parent_conn_mod = Mod,
                                parent_top = ParentTop,
                                fetch_interval = FetchInterval,
                                rpc_seed = Seed} = State) ->
    %% Parallel fetch top block from all configured parent chain nodes
    ParentTop1 =
        case fetch_parent_tops(Mod, ParentNodes, Seed) of
            {ok, ParentTop, _} ->
                %% No change, just check again later
                ok;
            {ok, NewParentTop, Node} ->
                %% Fetch the commitment Txs in the parent block from a node
                %% that had the majority answer
                _Commitments = fetch_commitments(Mod, Node, Seed, NewParentTop#top.hash)
                %% Commitments may include varying view on what is the latest 
                %%   block.
                %% Commitments include:
                %%   [{Committer, Committers view of child chain top hash}]
                %% - Run the algorithm to derive the consensus top block
                %% - Call the smart contract to elect new leader.
                %% - Notify conductor of new status
        end,
    if is_integer(FetchInterval) ->
        erlang:send_after(FetchInterval, self(), check_parent);
        true -> ok
    end,
    {noreply, State#state{rpc_seed = increment_seed(Seed),
                          parent_top = ParentTop1}};
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
fetch_parent_tops(Mod, ParentNodes, Seed) ->
    Fun = fun(Parent) -> fetch_parent_top(Mod, Parent, Seed) end,
    {Good, Errors} = pmap(Fun, ParentNodes, 10000),
    parent_top_consensus(Good, Errors, length(ParentNodes)).

fetch_parent_top(Mod, #{host := Host, port := Port,
                        user := User, password := Password} = Node, Seed) ->
    case Mod:get_latest_block(Host, Port, User, Password, Seed) of
        {ok, BlockHash, PrevHash, Height} ->
            Top = #top{hash = BlockHash,
                       prev_hash = PrevHash,
                       height = Height},
            {ok, {Top, Node}};
        Err ->
            Err
    end.

%% Check:
%% * multiple successful replies
%% * majority agree on block hash
parent_top_consensus(Good0, _Errors = [], TotalCount) ->
    Good = [{Top, Node} || {ok, {Top, Node}} <- Good0],
    Counts = lists:foldl(fun({Top, _Node}, Acc) ->
                            Fun = fun(V) -> V + 1 end,
                            maps:update_with(Top,Fun,1,Acc)
                        end, #{}, Good),
    {MostReturnedTop, Qty} = lists:last(lists:keysort(2, maps:to_list(Counts))),
    %% Need Qty to be > half of the total number of configured nodes ??
    if Qty > TotalCount div 2 ->
            {_, Node} = lists:keyfind(MostReturnedTop, 1, Good),
            {ok, MostReturnedTop, Node};
       true ->
            {error, no_parent_chain_agreement}
    end.

fetch_commitments(Mod, #{host := Host, port := Port,
                        user := User, password := Password}, Seed, NewParentHash) ->
    Mod:get_commitment_tx_in_block(Host, Port, User, Password, Seed, NewParentHash).

pmap(Fun, L, Timeout) ->
    Workers =
        lists:map(
            fun(E) ->
                spawn_monitor(
                    fun() ->
                        {WorkerPid, WorkerMRef} =
                            spawn_monitor(
                                fun() ->
                                    Top = Fun(E),
                                    exit({ok, Top})
                                end),
                        Result =
                            receive
                                {'DOWN', WorkerMRef, process, WorkerPid, Res} ->
                                    case Res of
                                        {ok, T} -> {ok, T};
                                        _       -> {error, failed}
                                    end
                            after Timeout -> {error, request_timeout}
                            end,
                        exit(Result)
                    end)
            end,
            L),
    pmap_gather(Workers, [], []).

pmap_gather([], Good, Errs) ->
    {Good, Errs};
pmap_gather([{Pid, MRef} | Pids], Good, Errs) ->
    receive
        {'DOWN', MRef, process, Pid, Res} ->
            case Res of
                {ok, GoodRes} -> pmap_gather(Pids, [GoodRes | Good], Errs);
                {error, _} = Err -> pmap_gather(Pids, Good, [Err | Errs])
            end
    end.

increment_seed(<<Num:?SEED_BYTES/unsigned-integer-unit:8>>) ->
    <<(Num + 1):?SEED_BYTES/unsigned-integer-unit:8>>;
increment_seed(Bin) when is_binary(Bin) ->
    crypto:strong_rand_bytes(?SEED_BYTES).

