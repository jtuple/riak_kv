%% -------------------------------------------------------------------
%%
%% riak_kv_bitcask_backend: Bitcask Driver for Riak
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(riak_kv_bitcask_backend).
-behavior(riak_kv_backend).
-author('Andy Gross <andy@basho.com>').
-author('Dave Smith <dizzyd@basho.com>').

%% KV Backend API
-export([start/2,
         stop/1,
         get/2,
         put/3,
         delete/2,
         list/1,
         list_bucket/2,
         fold/3,
         fold_keys/3,
         drop/1,
         is_empty/1,
         callback/3]).

%% Helper API
-export([key_counts/0]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("bitcask/include/bitcask.hrl").

-define(MERGE_CHECK_INTERVAL, timer:minutes(3)).

start(Partition, Config) ->
    %% Seed random number generator
    {_, A2, A3} = erlang:now(),
    random:seed(Partition, A2, A3),

    %% Get the data root directories
    DataRootConfig =
        case proplists:get_value(data_root, Config) of
            undefined ->
                case application:get_env(bitcask, data_root) of
                    {ok, Dir} ->
                        Dir;
                    _ ->
                        riak:stop("bitcask data_root unset, failing")
                end;
            Value ->
                Value
        end,

    PartitionFile = integer_to_list(Partition),

    %% Check if this partition's bitcask already exists
    ExistingDir =
        case DataRootConfig of
            {_, Roots} ->
                find_existing_dir(PartitionFile, Roots);
            _ ->
                none
        end,

    %% Pick one of the root directories using the given strategy
    DataDir = 
        case {ExistingDir, DataRootConfig} of
            {none, {Strategy, Dirs}} ->
                NDirs = case Strategy of
                            spread ->
                                [case file:list_dir(Dir) of
                                      {ok, Files} -> {length(Files), Dir};
                                      {error, _E} -> {0, Dir}
                                 end || Dir <- Dirs];
                            random ->
                                [{random:uniform(), Dir} || Dir <- Dirs]
                        end,
                lists:foldl(fun({_, Dir}, Chosen) ->
                                case Chosen of
                                    none ->
                                        TryDir = filename:join([Dir, PartitionFile]),
                                        case filelib:ensure_dir(TryDir) of
                                            ok ->
                                                Dir;
                                            {error, Reason} ->
                                                error_logger:error_msg("Failed to create bitcask dir ~s: ~p\n", [TryDir, Reason]),
                                                Chosen
                                        end;
                                    _ ->
                                        Chosen
                                end
                            end, none, lists:keysort(1, NDirs));
            {none, _} ->
                DataRootConfig;
            _ ->
                ExistingDir
        end,

    BitcaskRoot = filename:join([DataDir, PartitionFile]),

    %% Stop if we failed to find or create a directory
    case BitcaskRoot of
        none ->
            riak:stop("riak_kv_bitcask_backend failed to start.");
        _ ->
            ok
    end,

    BitcaskOpts = [{read_write, true}|Config],
    case bitcask:open(BitcaskRoot, BitcaskOpts) of
        Ref when is_reference(Ref) ->
            schedule_merge(Ref),
            maybe_schedule_sync(Ref),
            {ok, {Ref, BitcaskRoot}};
        {error, Reason2} ->
            {error, Reason2}
    end.


stop({Ref, _}) ->
    bitcask:close(Ref).


get({Ref, _}, BKey) ->
    Key = term_to_binary(BKey),
    case bitcask:get(Ref, Key) of
        {ok, Value} ->
            {ok, Value};
        not_found  ->
            {error, notfound};
        {error, Reason} ->
            {error, Reason}
    end.

put({Ref, _}, BKey, Val) ->
    Key = term_to_binary(BKey),
    case bitcask:put(Ref, Key, Val) of
        ok -> ok;
        {error, Reason} ->
            {error, Reason}
    end.

delete({Ref, _}, BKey) ->
    case bitcask:delete(Ref, term_to_binary(BKey)) of
        ok -> ok;
        {error, Reason} ->
            {error, Reason}
    end.

list({Ref, _}) ->
    case bitcask:list_keys(Ref) of
        KeyList when is_list(KeyList) ->
            [binary_to_term(K) || K <- KeyList];
        Other ->
            Other
    end.

list_bucket({Ref, _}, {filter, Bucket, Fun}) ->
    bitcask:fold_keys(Ref,
        fun(#bitcask_entry{key=BK},Acc) ->
                {B,K} = binary_to_term(BK),
                case B of
                    Bucket ->
                        case Fun(K) of
                            true -> [K|Acc];
                            false -> Acc
                        end;
                    _ ->
                        Acc
                end
        end, []);
list_bucket({Ref, _}, '_') ->
    bitcask:fold_keys(Ref,
        fun(#bitcask_entry{key=BK},Acc) ->
                {B,_K} = binary_to_term(BK),
                case lists:member(B,Acc) of
                    true -> Acc;
                    false -> [B|Acc]
                end
        end, []);
list_bucket({Ref, _}, Bucket) ->
    bitcask:fold_keys(Ref,
        fun(#bitcask_entry{key=BK},Acc) ->
                {B,K} = binary_to_term(BK),
                case B of
                    Bucket -> [K|Acc];
                    _ -> Acc
                end
        end, []).

fold({Ref, _}, Fun0, Acc0) ->
    %% When folding across the bitcask, the bucket/key tuple must
    %% be decoded. The intermediate binary_to_term call handles this
    %% and yields the expected fun({B, K}, Value, Acc)
    bitcask:fold(Ref,
                 fun(K, V, Acc) ->
                         Fun0(binary_to_term(K), V, Acc)
                 end,
                 Acc0).

fold_keys({Ref, _}, Fun, Acc) ->
    F = fun(#bitcask_entry{key=K}, Acc1) ->
                Fun(binary_to_term(K), Acc1) end,
    bitcask:fold_keys(Ref, F, Acc).

drop({Ref, BitcaskRoot}) ->
    %% todo: once bitcask has a more friendly drop function
    %%  of its own, use that instead.
    bitcask:close(Ref),
    {ok, FNs} = file:list_dir(BitcaskRoot),
    [file:delete(filename:join(BitcaskRoot, FN)) || FN <- FNs],
    file:del_dir(BitcaskRoot),
    ok.

is_empty({Ref, _}) ->
    %% Determining if a bitcask is empty requires us to find at least
    %% one value that is NOT a tombstone. Accomplish this by doing a fold_keys
    %% that forcibly bails on the very first key encountered.
    F = fun(_K, _Acc0) ->
                throw(found_one_value)
        end,
    case catch(bitcask:fold_keys(Ref, F, undefined)) of
        found_one_value ->
            false;
        _ ->
            true
    end.

callback({Ref, _}, Ref, {sync, SyncInterval}) when is_reference(Ref) ->
    bitcask:sync(Ref),
    schedule_sync(Ref, SyncInterval);
callback({Ref, BitcaskRoot}, Ref, merge_check) when is_reference(Ref) ->
    case bitcask:needs_merge(Ref) of
        {true, Files} ->
            bitcask_merge_worker:merge(BitcaskRoot, [], Files);
        false ->
            ok
    end,
    schedule_merge(Ref);
%% Ignore callbacks for other backends so multi backend works
callback(_State, _Ref, _Msg) ->
    ok.

key_counts() ->
    case application:get_env(bitcask, data_root) of
        {ok, RootDir} ->
            [begin
                 {Keys, _} = status(filename:join(RootDir, Dir)),
                 {Dir, Keys}
             end || Dir <- element(2, file:list_dir(RootDir))];
        {error, Reason} ->
            {error, Reason}
    end.

%% ===================================================================
%% Internal functions
%% ===================================================================

%% @private
%% Searches a list of directories for an existing partition bitcask
find_existing_dir(Find, Dirs) ->
    lists:foldl(fun(Dir, Found) ->
                        case file:list_dir(Dir) of
                            {ok, Files} ->
                                case lists:member(Find, Files) of
                                    true -> Dir;
                                    false -> Found
                                end;
                            _ ->
                                Found
                        end
                end,
                none,
                Dirs).

%% @private
%% Invoke bitcask:status/1 for a given directory
status(Dir) ->
    Ref = bitcask:open(Dir),
    Status = bitcask:status(Ref),
    bitcask:close(Ref),
    Status.

%% @private
%% Schedule sync (if necessary)
maybe_schedule_sync(Ref) when is_reference(Ref) ->
    case application:get_env(bitcask, sync_strategy) of
        {ok, {seconds, Seconds}} ->
            SyncIntervalMs = timer:seconds(Seconds),
            schedule_sync(Ref, SyncIntervalMs);
            %% erlang:send_after(SyncIntervalMs, self(),
            %%                   {?MODULE, {sync, SyncIntervalMs}});
        {ok, none} ->
            ok;
        BadStrategy ->
            error_logger:info_msg("Ignoring invalid bitcask sync strategy: ~p\n",
                                  [BadStrategy]),
            ok
    end.

schedule_sync(Ref, SyncIntervalMs) when is_reference(Ref) ->
    riak_kv_backend:callback_after(SyncIntervalMs, Ref, {sync, SyncIntervalMs}).

schedule_merge(Ref) when is_reference(Ref) ->
    riak_kv_backend:callback_after(?MERGE_CHECK_INTERVAL, Ref, merge_check).

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

simple_test() ->
    ?assertCmd("rm -rf test/bitcask-backend"),
    application:set_env(bitcask, data_root, "test/bitcask-backend"),
    riak_kv_backend:standard_test(?MODULE, []).

custom_config_test() ->
    ?assertCmd("rm -rf test/bitcask-backend"),
    application:set_env(bitcask, data_root, ""),
    riak_kv_backend:standard_test(?MODULE, [{data_root, "test/bitcask-backend"}]).

random_test() ->
    ?assertCmd("rm -rf test/bitcask-backend1"),
    ?assertCmd("rm -rf test/bitcask-backend2"),
    DataDirs = {random, ["test/bitcask-backend1", "test/bitcask-backend2"]},
    application:set_env(bitcask, data_root, DataDirs),
    riak_kv_backend:standard_test(?MODULE, []).

spread_config_test() ->
    ?assertCmd("rm -rf test/bitcask-backend1"),
    ?assertCmd("rm -rf test/bitcask-backend2"),
    ?assertCmd("mkdir test/bitcask-backend1"),
    ?assertCmd("touch test/bitcask-backend1/test"),
    DataDirs = {spread, ["test/bitcask-backend1", "test/bitcask-backend2"]},
    application:set_env(bitcask, data_root, ""),
    riak_kv_backend:standard_test(?MODULE, [{data_root, DataDirs}]),
    {ok, _Files} = file:list_dir("test/bitcask-backend2").

existing_dir_test() ->
    ?assertCmd("rm -rf test/bitcask-backend1"),
    ?assertCmd("rm -rf test/bitcask-backend2"),
    ?assertCmd("rm -rf test/bitcask-backend3"),
    ?assertCmd("rm -rf test/bitcask-backend4"),
    Dirs = ["test/bitcask-backend1", "test/bitcask-backend2",
            "test/bitcask-backend3", "test/bitcask-backend4"],
    ?assertEqual(none, find_existing_dir("42", Dirs)),

    {ok, BC} = start(42, [{data_root, {random, Dirs}}]),
    BKey = {<<"a">>, <<"b">>},
    put(BC, BKey, <<"c">>),
    stop(BC),

    %% Ensure we always open the same directory
    [[begin
          {ok, BC2} = start(42, [{data_root, {Mode, Dirs}}]),
          ?assertMatch({ok, <<"c">>}, get(BC2, BKey)),
          stop(BC2)
      end || _X <- lists:seq(1,20)] || Mode <- [random, spread]],

    ?assert(lists:member(find_existing_dir("42", Dirs), Dirs)).
    
-endif.
