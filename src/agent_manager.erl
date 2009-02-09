%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%% 
%% The Original Code is Spice Telphony.
%% 
%% The Initial Developer of the Original Code is 
%% Andrew Thompson and Micah Warren.
%% Portions created by the Initial Developers are Copyright (C) 
%% SpiceCSM. All Rights Reserved.

%% Contributor(s): 

%% Andrew Thompson <athompson at spicecsm dot com>
%% Micah Warren <mwarren at spicecsm dot com>
%% 

%% @doc Manages the agents, and attempts to start them.  Listener and connection modules refer back to this 
%% module when it is determined that it needs to start or find an agent.
-module(agent_manager).

%% depends on agent, util

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).

-export([start_link/0, start/0, stop/0, start_agent/1, query_agent/1, find_avail_agents_by_skill/1]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("call.hrl").
-include("agent.hrl").

% TODO wtf?
-type(mod_state() :: [{string(), pid()}]).

-spec(start_link/0 :: () -> {'ok', pid()}).
start_link() -> 
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
	
-spec(start/0 :: () -> {'ok', pid()}).
start() -> 
	gen_server:start({local, ?MODULE}, ?MODULE, [], []).

-spec(stop/0 :: () -> {'ok', pid()}).
stop() ->
	gen_server:call(?MODULE, stop).

init([]) -> 
	process_flag(trap_exit, true),
	case global:whereis_name(?MODULE) of
		undefined ->
				global:register_name(?MODULE, self(), {global, random_notify_name});
		GID -> 
			link(GID)
		end,
	{ok, dict:new()}.

-spec(start_agent/1 :: (Agent :: #agent{}) -> {'ok', pid()}).
start_agent(Agent) -> 
	gen_server:call(?MODULE, {start_agent, Agent}).

%% @doc Locally find all available agents with a particular skillset that contains the subset `Skills'.  Sorted by idle time, 
%% then the length of the list of skills the agent has;  this means idle time is less important.
-spec(find_avail_agents_by_skill/1 :: (Skills :: [atom()]) -> [{string(), pid(), #agent{}}]).
find_avail_agents_by_skill(Skills) ->
	?CONSOLE("skills passed:  ~p.", [Skills]),
	AvailSkilledAgents = [{K, V, AgState} || {K, V} <- gen_server:call(?MODULE, list_agents), AgState <- [agent:dump_state(V)], AgState#agent.state =:= idle, util:list_contains_all(AgState#agent.skills, Skills)],
	AvailSkilledAgentsByIdleTime = lists:sort(fun({_K1, _V1, State1}, {_K2, _V2, State2}) -> State1#agent.lastchangetimestamp =< State2#agent.lastchangetimestamp end, AvailSkilledAgents), 
	lists:sort(fun({_K1, _V1, State1}, {_K2, _V2, State2}) -> length(State1#agent.skills) =< length(State2#agent.skills) end, AvailSkilledAgentsByIdleTime).

%% @doc Check if an agent idetified by agent record or login name string of `Login' exists
-spec(query_agent/1 ::	(Agent :: #agent{}) -> {'true', pid()} | 'false';
						(Login :: string()) -> {'true', pid()} | 'false').
query_agent(#agent{login=Login}) -> 
	gen_server:call(?MODULE, {exists, Login});
query_agent(Login) -> 
	gen_server:call(?MODULE, {exists, Login}).

% TODO stub for syncing agents across nodes
-spec(sync_agents/1 :: (Dict :: mod_state()) -> mod_state()).
sync_agents(Dict) -> 
	Dict.

handle_call({start_agent, #agent{login=Login} = Agent}, _From, State) ->
	% starts a new agent and returns the state of that agent.
	case dict:find(Login, State) of 
		{ok, Pid} -> 
			{reply, {exists, Pid}, State};
		error -> 
			Self = self(),
			case global:whereis_name(?MODULE) of
				Self -> 
					{ok, Pid} = agent:start(Agent),
					erlang:monitor(process, Pid),
					{reply, {ok, Pid}, dict:store(Login, Pid, State)};
				undefined -> 
					global:register_name(?MODULE, self(), {global, random_notify_name}),
					{ok, Pid} = agent:start(Agent),
					erlang:monitor(process, Pid),
					{reply, {ok, Pid}, dict:store(Login, Pid, State)};
				_ -> 
					try gen_server:call({global, ?MODULE}, {exists, Login}) of 
						{true, Pid} ->
							{reply, {exists, Pid}, State};
						false -> 
							{ok, Pid} = agent:start(Agent),
							erlang:monitor(process, Pid),
							gen_server:call({global, ?MODULE}, {notify, Login, Pid}), % like the queue manager, handle a timeout.
							{reply, {ok, Pid}, dict:store(Login, Pid, State)}
					catch
						exit:{timeout, _} -> 
							global:register_name(?MODULE, self(), {global, random_notify_name}),
							{ok, Pid} = agent:start(Agent),
							erlang:monitor(process, Pid),
							{reply, {ok, Pid}, dict:store(Login, Pid, State)}
					end
			end
	end;

handle_call({exists, Login}, _From, State) ->
	case dict:find(Login, State) of 
		{ok, Pid} -> 
			{reply, {true, Pid}, State};
		error -> 
			{reply, false, State}
	end;

handle_call({notify, Login, Pid}, _From, State) -> 
	{reply, ok, dict:store(Login, Pid, State)};

handle_call(list_agents, _From, State) ->
	{reply, dict:to_list(State), State};

handle_call(stop, _From, State) ->
	{stop, normal, ok, State};

handle_call(Request, _From, State) ->
	{reply, {unknown_call, Request}, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({'EXIT', From, _Reason}, State) -> 
	{noreply, dict:filter(
		fun(_Key, Val) -> 
			node(From) =/= node(Val)
		end,
	State)
	};
handle_info({'DOWN', _MonitorRef, process, Object, _Info}, State) -> 
	?CONSOLE("agent_manager is taking care of an agent down.", []),
	{noreply, dict:filter(fun(_Key, Value) -> Value =/= Object end, State)};
handle_info({global_name_conflict, _Name}, State) ->
	?CONSOLE("Node ~p lost election", [node()]),
	link(global:whereis_name(?MODULE)),
	{noreply, sync_agents(State)};

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

-ifdef('EUNIT').

handle_call_start_test() ->
	?assertMatch({ok, _Pid}, start()),
	stop().

single_node_test_() -> 
	Agent = #agent{login="testagent"},
	{foreach,
		fun() -> 
			start(),
			{}
		end,
		fun({}) -> 
			stop()
		end,
		[
			{"Start New Agent", 
				fun() -> 
					{ok, Pid} = gen_server:call(?MODULE, {start_agent, Agent}),
					?assertMatch({ok, released}, agent:query_state(Pid))
				end
			},
			{"Start Existing Agent",
				fun() -> 
					{ok, Pid} = gen_server:call(?MODULE, {start_agent, Agent}),
					?assertMatch({exists, Pid}, gen_server:call(?MODULE, {start_agent, Agent}))
				end
			},
			{"Lookup agent by name",
				fun() -> 
					{ok, Pid} = gen_server:call(?MODULE, {start_agent, Agent}),
					Login = Agent#agent.login,
					?assertMatch({true, Pid}, query_agent(Login))
				end
			}, {
				"Find available agents with a skillset that matches but is the shortest",
				fun() ->
					Agent1 = #agent{login="Agent1"},
					Agent2 = #agent{login="Agent2", skills=[english, '_agent', '_node', coolskill, otherskill]},
					Agent3 = #agent{login="Agent3", skills=[english, '_agent', '_node', coolskill]},
					{ok, Agent1Pid} = gen_server:call(?MODULE, {start_agent, Agent1}),
					{ok, Agent2Pid} = gen_server:call(?MODULE, {start_agent, Agent2}),
					{ok, Agent3Pid} = gen_server:call(?MODULE, {start_agent, Agent3}),
					agent:set_state(Agent1Pid, idle),
					agent:set_state(Agent3Pid, idle),
					?assertMatch([{"Agent3", Agent3Pid, _State}], find_avail_agents_by_skill([coolskill])),
					agent:set_state(Agent2Pid, idle),
					?assertMatch([{"Agent3", Agent3Pid, _State1}, {"Agent2", Agent2Pid, _State2}], find_avail_agents_by_skill([coolskill]))
				end
			}, {
				"Find available agents with a skillset that matches but is longest idle",
				fun() ->
					Agent1 = #agent{login="Agent1"},
					Agent2 = #agent{login="Agent2", skills=[english, '_agent', '_node', coolskill]},
					Agent3 = #agent{login="Agent3", skills=[english, '_agent', '_node', coolskill]},
					{ok, Agent1Pid} = gen_server:call(?MODULE, {start_agent, Agent1}),
					{ok, Agent2Pid} = gen_server:call(?MODULE, {start_agent, Agent2}),
					{ok, Agent3Pid} = gen_server:call(?MODULE, {start_agent, Agent3}),
					agent:set_state(Agent1Pid, idle),
					agent:set_state(Agent3Pid, idle),
					?assertMatch([{"Agent3", Agent3Pid, _State}], find_avail_agents_by_skill([coolskill])),
					receive after 500 -> ok end,
					agent:set_state(Agent2Pid, idle),
					?assertMatch([{"Agent3", Agent3Pid, _State1}, {"Agent2", Agent2Pid, _State2}], find_avail_agents_by_skill([coolskill]))
				end
			}

		]
	}.



get_nodes() ->
	[_Name, Host] = string:tokens(atom_to_list(node()), "@"),
	{list_to_atom(lists:append("master@", Host)), list_to_atom(lists:append("slave@", Host))}.

multi_node_test_() -> 
	{Master, Slave} = get_nodes(),
	Agent = #agent{login="testagent"},
	Agent2 = #agent{login="testagent2"},
	{
		foreach,
		fun() -> 
			slave:start(net_adm:localhost(), master, " -pa debug_ebin"), 
			slave:start(net_adm:localhost(), slave, " -pa debug_ebin"),
			cover:start([Master, Slave]),
			rpc:call(Master, global, sync, []),
			rpc:call(Slave, global, sync, []),
			rpc:call(Master, agent_manager, start, []),
			rpc:call(Slave, agent_manager, start, []),
			rpc:call(Master, global, sync, []),
			rpc:call(Slave, global, sync, []),
			{}
		end,
		fun({}) -> 
			cover:stop([Master, Slave]),
			slave:stop(Master),
			slave:stop(Slave),
			ok
		end,
		[
			{
				"Slave picks up added agent",
				fun() -> 
					{ok, Pid} = rpc:call(Master, agent_manager, start_agent, [Agent]),
					?assertMatch({exists, Pid}, rpc:call(Slave, agent_manager, start_agent, [Agent]))
				end
			},
			{
				"Slave continues after master dies",
				fun() -> 
					{ok, _Pid} = rpc:call(Master, agent_manager, start_agent, [Agent]),
					rpc:call(Master, erlang, disconnect_node, [Slave]),
					rpc:call(Slave, erlang, disconnect_node, [Master]),
					?assertMatch({ok, _NewPid}, rpc:call(Slave, agent_manager, start_agent, [Agent]))
				end
			},
			{
				"Slave becomes master after master dies",
				fun() -> 
					rpc:call(Master, erlang, disconnect_node, [Slave]),
					cover:stop([Master]),
					slave:stop(Master),
					
					?assertMatch(undefined, global:whereis_name(?MODULE)),
					?assertMatch({ok, _Pid}, rpc:call(Slave, agent_manager, start_agent, [Agent])),
					?assertMatch({true, _Pid}, rpc:call(Slave, agent_manager, query_agent, [Agent])),
					Globalwhere = global:whereis_name(agent_manager),
					Slaveself = rpc:call(Slave, erlang, whereis, [agent_manager]),
					?assertMatch(Globalwhere, Slaveself)
				end
			}, {
				"Net Split",
				fun() ->
					rpc:call(Master, erlang, disconnect_node, [Slave]),
					rpc:call(Slave, erlang, disconnect_node, [Master]),


					?assertMatch({ok, _Pid}, rpc:call(Master, agent_manager, start_agent, [Agent])),
					?assertMatch({ok, _Pid}, rpc:call(Slave, agent_manager, start_agent, [Agent])),

					Pinged = rpc:call(Master, net_adm, ping, [Slave]),
					Pinged = rpc:call(Slave, net_adm, ping, [Master]),

					?assert(Pinged =:= pong),

					rpc:call(Master, global, sync, []),
					rpc:call(Slave, global, sync, []),

					
					Newmaster = node(global:whereis_name(?MODULE)),

					receive after 1000 -> ok end,
					?assertMatch(Newmaster, Master)
				end
			}, {
				"Master removes agents for a dead node",
				fun() ->
					?assertMatch({ok, _Pid}, rpc:call(Slave, agent_manager, start_agent, [Agent])),
					?assertMatch({ok, _Pid}, rpc:call(Master, agent_manager, start_agent, [Agent2])),
					?assertMatch({true, _Pid}, rpc:call(Master, agent_manager, query_agent, [Agent])),
					rpc:call(Master, erlang, disconnect_node, [Slave]),
					cover:stop(Slave),
					slave:stop(Slave),
					?assertEqual(false, rpc:call(Master, agent_manager, query_agent, [Agent])),
					?assertMatch({true, _Pid}, rpc:call(Master, agent_manager, query_agent, [Agent2])),
					?assertMatch({ok, _Pid}, rpc:call(Master, agent_manager, start_agent, [Agent]))
				end
			}
		]
	}.

-define(MYSERVERFUNC, fun() -> start(), {?MODULE, fun() -> stop() end} end).

-include("gen_server_test.hrl").


-endif.

