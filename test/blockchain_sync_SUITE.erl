-module(blockchain_sync_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("blockchain.hrl").

-export([
    all/0
]).

-export([
    basic/1
]).

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [basic].

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
basic(_Config) ->
    BaseDir = "data/sync_SUITE/basic",
    Balance = 5000,
    BlocksN = 100,
    {ok, Sup, {PrivKey, PubKey}, _Opts} = test_utils:init(BaseDir),
    {ok, ConsensusMembers} = test_utils:init_chain(Balance, {PrivKey, PubKey}),

    % Create BlocksN empty blocks
    Blocks = create_blocks(BlocksN, ConsensusMembers),
    LastBlock = lists:last(Blocks),

    % Simulate other chain with sync handler only
    {ok, SimSwarm} = libp2p_swarm:start(sync_SUITE_sim, [{libp2p_nat, [{enabled, false}]}]),
    ok = libp2p_swarm:listen(SimSwarm, "/ip4/0.0.0.0/tcp/0"),
    SimDir = "data/sync_SUITE/basic_sim",
    [blockchain_block:save(blockchain_block:hash_block(B), B, SimDir) || B <- Blocks],
    ok = libp2p_swarm:add_stream_handler(
        SimSwarm
        ,?SYNC_PROTOCOL
        ,{libp2p_framed_stream, server, [blockchain_sync_handler, ?MODULE, SimDir]}
    ),
    % This is just to connect the 2 swarms
    [ListenAddr|_] = libp2p_swarm:listen_addrs(blockchain_swarm:swarm()),
    {ok, _} = libp2p_swarm:connect(SimSwarm, ListenAddr),
    ok = test_utils:wait_until(fun() -> erlang:length(libp2p_peerbook:values(libp2p_swarm:peerbook(blockchain_swarm:swarm()))) > 1 end),

    % Simulate add block from other chain
    ok = blockchain_worker:add_block(LastBlock, libp2p_swarm:address(SimSwarm)),

    ok = test_utils:wait_until(fun() -> BlocksN + 1 =:= blockchain_worker:height() end),
    ?assertEqual(blockchain_block:hash_block(LastBlock), blockchain_worker:head_hash()),
    ?assertEqual(LastBlock, blockchain_worker:head_block()),
    true = erlang:exit(Sup, normal),
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
create_blocks(N, ConsensusMembers) ->
    create_blocks(N, ConsensusMembers, []).

create_blocks(0, _, Blocks) ->
    lists:reverse(Blocks);
create_blocks(N, ConsensusMembers, []=Blocks) ->
    PrevHash = blockchain_worker:head_hash(),
    Height = blockchain_worker:height() + 1,
    Block0 = blockchain_block:new(PrevHash, Height, [], <<>>, #{}),
    BinBlock = erlang:term_to_binary(blockchain_block:remove_signature(Block0)),
    Signatures = signatures(ConsensusMembers, BinBlock),
    Block1 = blockchain_block:sign_block(erlang:term_to_binary(Signatures), Block0),
    create_blocks(N-1, ConsensusMembers, [Block1|Blocks]);
create_blocks(N, ConsensusMembers, [LastBlock|_]=Blocks) ->
    PrevHash = blockchain_block:hash_block(LastBlock),
    Height = blockchain_block:height(LastBlock) + 1,
    Block0 = blockchain_block:new(PrevHash, Height, [], <<>>, #{}),
    BinBlock = erlang:term_to_binary(blockchain_block:remove_signature(Block0)),
    Signatures = signatures(ConsensusMembers, BinBlock),
    Block1 = blockchain_block:sign_block(erlang:term_to_binary(Signatures), Block0),
    create_blocks(N-1, ConsensusMembers, [Block1|Blocks]).

signatures(ConsensusMembers, BinBlock) ->
    lists:foldl(
        fun({A, {_, _, F}}, Acc) ->
            Sig = F(BinBlock),
            [{A, Sig}|Acc]
        end
        ,[]
        ,ConsensusMembers
    ).