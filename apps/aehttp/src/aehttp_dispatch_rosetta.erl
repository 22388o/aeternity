-module(aehttp_dispatch_rosetta).

-export([forbidden/2]).
-export([handle_request/3]).

-import(aeu_debug, [pp/1]).
-import(aehttp_helpers, [ 
                          when_stable/1
                        ]).

-compile({parse_transform, lager_transform}).

-define(READ_Q, http_read).
-define(WRITE_Q, http_update).
-define(NO_Q, no_queue).

%% dry run limits
-define(DEFAULT_GAS_LIMIT, 6000000).
-define(DEFAULT_CALL_REQ_GAS_LIMIT, 1000000).

-define(TC(Expr, Msg), begin {Time, Res} = timer:tc(fun() -> Expr end), lager:debug("[~p] Msg = ~p", [Time, Msg]), Res end).

-define(ROSETTA_ERR_NW_STATUS_ERR,   1).
-define(ROSETTA_ERR_INVALID_NETWORK, 2).
-define(ROSETTA_ERR_BLOCK_NOT_FOUND, 3).
-define(ROSETTA_ERR_CHAIN_TOO_SHORT, 4).

-spec forbidden( Mod :: module(), OperationID :: atom() ) -> boolean().
forbidden(_Mod, _OpId) -> false.

-spec handle_request(
        OperationID :: atom(),
        Req :: cowboy_req:req(),
        Context :: #{}
       ) -> {Status :: cowboy:http_status(), Headers :: list(), Body :: map()}.
handle_request(OperationID, Req, Context) ->
    run(queue(OperationID),
        fun() ->
                ?TC(handle_request_(OperationID, Req, Context), Req)
        end).

%% run(no_queue, F) -> F();
run(Queue, F) ->
    try when_stable(
          fun() ->
                  aec_jobs_queues:run(Queue, F)
          end)
    catch
        error:{rejected, _} ->
            {503, [], #{reason => <<"Temporary overload">>}};
        error:timeout ->
            {503, [], #{reason => <<"Not yet started">>}};
        Class:Reason:Stacktrace ->
            lager:error("CRASH ~p ~p, ~p", [Class, Reason, Stacktrace]),
            {500, [], #{reason => <<"Internal server error">>}}
    end.

%% read transactions
%% Data API - Network
queue('networkList')            -> ?READ_Q;
queue('networkOptions')         -> ?READ_Q;
queue('networkStatus')          -> ?READ_Q;

%% Data API - Account
queue('accountBalance')         -> ?READ_Q;
queue('accountCoins')           -> ?READ_Q;

%% Data API - Block
queue('block')                  -> ?READ_Q;
queue('blockTransaction')       -> ?READ_Q;

%% Data API - Mempool
queue('mempool')                -> ?READ_Q;
queue('mempoolTransaction')     -> ?READ_Q;

%% Construction API - Construction
queue('constructionCombine')    -> ?WRITE_Q;
queue('constructionDerive')     -> ?WRITE_Q;
queue('constructionHash')       -> ?WRITE_Q;
queue('constructionMetadata')   -> ?WRITE_Q;
queue('constructionParse')      -> ?WRITE_Q;
queue('constructionPayloads')   -> ?WRITE_Q;
queue('constructionPreprocess') -> ?WRITE_Q;
queue('constructionSubmit')     -> ?WRITE_Q;

%% Indexers
queue('call')                   -> ?READ_Q;
queue('eventsBlocks')           -> ?READ_Q;
queue('searchTransactions')     -> ?READ_Q;

queue(_)                        -> ?WRITE_Q.

handle_request_('networkList', _, _Context) ->
    Resp = #{<<"network_identifiers">> => 
                 [#{<<"blockchain">> => aeapi:blockchain_name(),
                    <<"network">> => aeapi:network_id()
                   }
                 ]
            },
    {200, [], Resp};
handle_request_('networkOptions', _, _Context) ->
    Resp = #{<<"version">> => #{<<"rosetta_version">> => <<"1.4.10">>,
                                <<"node_version">> => aeapi:node_version(),
                                <<"metadata">> => #{<<"node_revision">> => aeapi:node_revision()}},
             <<"allow">> => #{
                              <<"operation_statuses">> => [#{<<"status">> => <<"SUCCESS">>,
                                                             <<"successful">> => true},
                                                           #{<<"status">> => <<"FAILED">>,
                                                             <<"successful">> => false}],
                              <<"operation_types">> => ae_operation_types(),
                              <<"errors">> => rosetta_errors(),
                              <<"historical_balance_lookup">> => true,
                              <<"call_methods">> => [<<"TODO">>],
                              <<"balance_exemptions">> => [],
                              <<"mempool_coins">> => false
                             }
            },
    {200, [], Resp};
handle_request_('networkStatus', _, _Context) ->
    try
        {ok, TopBlock} = aeapi:top_key_block(),
        CurrentBlock = aeapi:prev_block(TopBlock),
        CurrentBlockIdentifier = format_block_identifier(CurrentBlock),
        CurrentBlockTimestamp = aec_blocks:time_in_msecs(CurrentBlock),
        GenesisBlockIdentifier = format_block_identifier(aec_chain:genesis_block()),
        {Syncing, SyncProgress, TargetHeight} = aeapi:sync_progress(),
        Synced = case {Syncing, SyncProgress} of
                     {false, 100.0} -> true;
                     _ -> false
                 end,
        SyncStatus0 = #{<<"synced">> => Synced},
        SyncStatus = case Synced of
                         true ->
                             SyncStatus0;
                         false ->
                             SyncStatus0#{<<"target_index">> => TargetHeight}
                     end,
        Peers = aeapi:connected_peers(),
        PeersFormatted = lists:map(
                           fun(Peer) ->
                                   #{<<"peer_id">> => aeser_api_encoder:encode(peer_pubkey, aec_peer:id(Peer)),
                                     <<"metadata">> => #{<<"ip">> => aec_peer:ip(Peer),
                                                         <<"port">> => aec_peer:port(Peer)}}
                           end, Peers),
        Resp = #{<<"current_block_identifier">> => CurrentBlockIdentifier,
                 <<"current_block_timestamp">> => CurrentBlockTimestamp,
                 <<"genesis_block_identifier">> => GenesisBlockIdentifier,
                 <<"sync_status">> => SyncStatus,
                 <<"peers">> => PeersFormatted},
        {200, [], Resp}
    catch Class:Rsn:Stacktrace ->
            lager:error(
              ">>> Error determining networkStatus: ~p, ~p~n~p~n", [Class, Rsn, Stacktrace]),
            ErrResp = rosetta_error_response(?ROSETTA_ERR_NW_STATUS_ERR),
            {200, [], ErrResp}
    end;

handle_request_('accountBalance', _, _Context) ->
    {501, [], #{}};
handle_request_('accountCoins', _, _Context) ->
    {501, [], #{}};

%% Data API - Block
handle_request_('block', #{'BlockRequest' := 
                               #{<<"network_identifier">> := 
                                     #{<<"blockchain">> := <<"aeternity">>,
                                       <<"network">> := Network}} = Req}, _Context) ->
    try
        case aec_governance:get_network_id() of
            Network ->
                ok;
            _ ->
                throw(invalid_network)
        end,
        Block = case maps:get(<<"block_identifier">>, Req) of
                    #{<<"index">> := Index} ->
                        case aeapi:key_block_by_height(Index) of
                            {ok, Block0} ->
                                Block0;
                            {error, Err} ->
                                throw(Err)
                        end;
                    #{<<"hash">> := Hash} ->
                        case aeapi:key_block_by_hash(Hash) of
                            error ->
                                throw(block_not_found);
                            {ok, Block0} ->
                                Block0
                        end;
                    _ ->
                        aeapi:prev_block(aeapi:current_block())
                end,
        BlockFmt = format_block(Block),
        Resp = BlockFmt#{<<"metadata">> => #{}},
        {200, [], Resp}
    catch throw:invalid_network ->
            {200, [], rosetta_error_response(?ROSETTA_ERR_INVALID_NETWORK)};
          throw:block_not_found ->
            {200, [], rosetta_error_response(?ROSETTA_ERR_BLOCK_NOT_FOUND)};
          throw:chain_too_short ->
            {200, [], rosetta_error_response(?ROSETTA_ERR_CHAIN_TOO_SHORT)}
    end;
handle_request_('blockTransaction', _, _Context) ->
    {501, [], #{}};
handle_request_('call', _, _Context) ->
    {501, [], #{}};
handle_request_('constructionCombine', _, _Context) ->
    {501, [], #{}};
handle_request_('constructionDerive', _, _Context) ->
    {501, [], #{}};
handle_request_('constructionHash', _, _Context) ->
    {501, [], #{}};
handle_request_('constructionMetadata', _, _Context) ->
    {501, [], #{}};
handle_request_('constructionParse', _, _Context) ->
    {501, [], #{}};
handle_request_('constructionPayloads', _, _Context) ->
    {501, [], #{}};
handle_request_('constructionPreprocess', _, _Context) ->
    {501, [], #{}};
handle_request_('constructionSubmit', _, _Context) ->
    {501, [], #{}};
handle_request_('eventsBlocks', _, _Context) ->
    {501, [], #{}};
handle_request_('mempool', _, _Context) ->
    {501, [], #{}};
handle_request_('mempoolTransaction', _, _Context) ->
    {501, [], #{}};
handle_request_('searchTransactions', _, _Context) ->
    {501, [], #{}};

handle_request_(OperationID, Req, Context) ->
    error_logger:error_msg(
      ">>> Got not implemented request to process: ~p~n",
      [{OperationID, Req, Context}]
     ),
    {501, [], #{}}.

ae_operation_types() ->
    [aetx:type_to_swagger_name(X) || X <- [spend_tx,
                                           oracle_register_tx,
                                           oracle_extend_tx,
                                           oracle_query_tx,
                                           oracle_response_tx,
                                           name_preclaim_tx,
                                           name_claim_tx,
                                           name_transfer_tx,
                                           name_update_tx,
                                           name_revoke_tx,
                                           contract_create_tx,
                                           contract_call_tx,
                                           ga_attach_tx,
                                           ga_meta_tx,
                                           channel_create_tx,
                                           channel_deposit_tx,
                                           channel_withdraw_tx,
                                           channel_force_progress_tx,
                                           channel_close_mutual_tx,
                                           channel_close_solo_tx,
                                           channel_slash_tx,
                                           channel_settle_tx,
                                           paying_for_tx]].

rosetta_errors() ->
    [rosetta_error_response(X) || X <- [?ROSETTA_ERR_NW_STATUS_ERR,
                                        ?ROSETTA_ERR_INVALID_NETWORK,
                                        ?ROSETTA_ERR_BLOCK_NOT_FOUND,
                                        ?ROSETTA_ERR_CHAIN_TOO_SHORT]].

-spec format_block(aec_blocks:block()) -> #{}.
format_block(Block) ->
    PrevBlock = aeapi:prev_block(Block),
    #{
      <<"block_identifier">> => format_block_identifier(Block),
      <<"parent_block_identifier">> => format_block_identifier(PrevBlock),
      <<"timestamp">> => aeapi:block_time_in_msecs(Block),
      <<"transactions">> => format_block_txs(aeapi:block_txs(Block))
     }.

format_block_identifier(undefined) ->
    #{<<"index">> => 0,
      <<"hash">> => <<>>};
format_block_identifier(Block) ->
    #{<<"index">> => aeapi:block_height(Block),
      <<"hash">> => aeapi:printable_block_hash(Block)}.

format_block_txs(Txs) ->
    {_, FormattedTxs} = lists:foldl(
                          fun(SignedTx, {Offset, Acc}) ->
                                  Tx = aetx_sign:tx(SignedTx),
                                  TxType = aetx:tx_type(Tx),
                                  X2 = format_tx(SignedTx, Offset, TxType),
                                  OffsetIncrement = 1,
                                  {Offset + OffsetIncrement, [X2 | Acc]}
                          end, {0, []}, Txs),
    lists:reverse(FormattedTxs).

format_tx(SignedTx, Offset, TxType) ->
    #{
      <<"transaction_identifier">> => #{<<"hash">> => aeser_api_encoder:encode(tx_hash, aetx_sign:hash(SignedTx))},
      <<"operations">> => tx_operations(SignedTx, Offset, TxType)
     }.

tx_operations(_Tx, Offset, TxType) ->
    [#{
       <<"operation_identifier">> => #{<<"index">> => Offset},
       <<"type">> => aetx:type_to_swagger_name(TxType)
      }].

rosetta_error_response(ErrCode) ->
    rosetta_error_response(ErrCode, rosetta_err_retriable(ErrCode)).

rosetta_error_response(ErrCode, Retriable) when is_integer(ErrCode),
                                                is_boolean(Retriable) ->
    rosetta_error_response(ErrCode, Retriable, undefined).

rosetta_error_response(ErrCode, Retriable, Details) when is_integer(ErrCode),
                                                         is_boolean(Retriable) ->
    Err = #{<<"code">> => ErrCode,
            <<"message">> => rosetta_err_msg(ErrCode),
            <<"retriable">> => Retriable
           },
    case Details of
        undefined ->
            Err;
        #{} ->
            Err#{<<"details">> => Details}
    end.

rosetta_err_msg(?ROSETTA_ERR_NW_STATUS_ERR)   -> <<"Error determining networkStatus">>;
rosetta_err_msg(?ROSETTA_ERR_INVALID_NETWORK) -> <<"Invalid network specified">>;
rosetta_err_msg(?ROSETTA_ERR_BLOCK_NOT_FOUND) -> <<"Specified block not found">>;
rosetta_err_msg(?ROSETTA_ERR_CHAIN_TOO_SHORT) -> <<"Chain too short">>.

rosetta_err_retriable(?ROSETTA_ERR_NW_STATUS_ERR)   -> true;
rosetta_err_retriable(?ROSETTA_ERR_BLOCK_NOT_FOUND) -> true;
rosetta_err_retriable(?ROSETTA_ERR_CHAIN_TOO_SHORT) -> true;
rosetta_err_retriable(_)                            -> false.