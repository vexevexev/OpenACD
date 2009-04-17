%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is Spice Telephony.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

%% @doc The web management module.  Uses mochiweb for the heavy lifting.  Listens on port 9999 by default.
-module(cpx_web_management).
-author("Micah").

-define(PORT, 9999).
-define(WEB_DEFAULTS, [{name, ?MODULE}, {port, ?PORT}]).
-define(COOKIE, {_Reflist, _Salt, _Login}).

-include("call.hrl").
-include("agent.hrl").
-include("queue.hrl").
-include("cpx.hrl").
-include_lib("stdlib/include/qlc.hrl").

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([start/0, stop/0, loop/1]).

% TODO configure this to start by default with a default configureation (cpx_supervisor_conf)
%% @doc Start the web management server unlinked to the parent process.
-spec(start/0 :: () -> {'ok', pid()}).
start() ->
	?CONSOLE("Starting mochiweb...", []),
	ets:new(cpx_management_logins, [set, public, named_table]),
	mochiweb_http:start([{loop, {?MODULE, loop}} | ?WEB_DEFAULTS]).

%% @doc Stops the web management.
-spec(stop/0 :: () -> 'ok').
stop() -> 
	ets:delete(cpx_management_logins),
	mochiweb_http:stop(?MODULE).

-spec(loop/1 :: (Req :: atom()) -> any()).
loop(Req) ->
	Path = Req:get(path),
	Post = Req:parse_post(),
	case parse_path(Path) of
		{file, {File, Docroot}} ->
			Cookies = Req:parse_cookie(),
			case check_cookie(Cookies) of
				badcookie ->
					Ref = erlang:ref_to_list(make_ref()),
					Cookie = io_lib:format("cpx_management=~p; path=/", [Ref]),
					ets:insert(cpx_management_logins, {Ref, undefined, undefined}),
					Req:serve_file(File, Docroot, [{"Set-Cookie", Cookie}]);
				{_Reflist, _Salt, _Login} ->
					Req:serve_file(File, Docroot)
			end;
		{api, Api} ->
			Out = api(Api, check_cookie(Req:parse_cookie()), Post),
			Req:respond(Out)
	end.

%% =====
%% General requests
%% =====
api(checkcookie, Cookie, _Post) ->
	case Cookie of
		badcookie ->
			Reflist = erlang:ref_to_list(make_ref()),
			NewCookie = io_lib:format("cpx_management=~p; path=/", [Reflist]),
			ets:insert(cpx_management_logins, {Reflist, undefined, undefined}),
			{200, [{"Set-Cookie", NewCookie}], mochijson2:encode({struct, [{<<"success">>, false}]})};
		{_Reflist, _Salt, undefined} ->
			{200, [], mochijson2:encode({struct, [{<<"success">>, false}]})};
		{_Reflist, _Salt, Login} ->
			{200, [], mochijson2:encode({struct, [{<<"success">>, true}, {<<"login">>, list_to_binary(Login)}]})}
	end;
api(_Apirequest, badcookie, _Post) ->
	Reflist = erlang:ref_to_list(make_ref()),
	Cookie = io_lib:format("cpx_management=~p; path=/", [Reflist]),
	ets:insert(cpx_management_logins, {Reflist, undefined, undefined}),
	{403, [{"Set-Cookie", Cookie}], <<"Cookie reset, retry.">>};
api(getsalt, {Reflist, _Salt, Login}, _Post) ->
	Newsalt = integer_to_list(crypto:rand_uniform(0, 4294967295)),
	ets:insert(cpx_management_logins, {Reflist, Newsalt, Login}),
	{200, [], mochijson2:encode({struct, [{success, true}, {message, <<"Salt created, check salt property">>}, {salt, list_to_binary(Newsalt)}]})};
api(login, {_Reflist, undefined, _Login}, _Post)  ->
	{200, [], mochijson2:encode({struct, [{success, false}, {message, <<"No salt set">>}]})};
api(login, {Reflist, Salt, _Login}, Post) ->
	Username = proplists:get_value("username", Post, ""),
	Password = proplists:get_value("password", Post, ""),
	case agent_auth:auth(Username, Password, Salt) of
		deny ->
			{200, [], mochijson2:encode({struct, [{success, false}, {message, <<"login err">>}]})};
		{allow, _Skills, admin, _Profile} ->
			ets:insert(cpx_management_logins, {Reflist, Salt, Username}),
			{200, [], mochijson2:encode({struct, [{success, true}, {message, <<"logged in">>}]})};
		{allow, _Skills, _Security, _Profile} ->
			{200, [], mochijson2:encode({struct, [{success, false}, {message, <<"login err">>}]})}
	end;
api(logout, {Reflist, _Salt, _Login}, _Post) ->
	ets:delete(cpx_management_logins, Reflist),
	{200, [], mochijson2:encode({struct, [{success, true}]})};

%% =====
%% agents -> modules
%% =====
api({agents, "modules", "update"}, ?COOKIE, Post) ->
	Tcpout = case proplists:get_value("agentModuleTCPListen", Post) of
		undefined ->
			cpx_supervisor:destroy(agent_tcp_listener),
			{struct, [{success, true}, {<<"message">>, <<"TCP Server disabled">>}]};
		Tcpport ->
			OldTcpPort = case cpx_supervisor:get_conf(agent_tcp_listener) of
				TcpRecord when is_record(TcpRecord, cpx_conf) ->
					lists:nth(1, TcpRecord#cpx_conf.start_args);
				_Else1 ->
					undefined
			end,
			try list_to_integer(Tcpport) of
				OldTcpPort ->
					{struct, [{success, true}, {<<"message">>, <<"Nothing to do">>}]};
				N when N >= 1024, N =< 65535 ->
					cpx_supervisor:update_conf(agent_tcp_listener, agent_tcp_listener, start_link, [N]),
					{struct, [{success, true}, {<<"message">>, <<"TCP Server enabled">>}]};
				_N ->
					{struct, [{success, false}, {<<"message">>, <<"Listen port out of range">>}]}
			catch
				error:badarg ->
					{struct, [{success, false}, {<<"message">>, <<"Listen port not a number">>}]}
			end
	end,
	Webout = case proplists:get_value("agentModuleWebListen", Post) of
		undefined ->
			cpx_supervisor:destroy(agent_web_listener),
			{struct, [{success, true}, {<<"message">>, <<"Web Server disabled">>}]};
		Webport ->
			OldWebPort = case cpx_supervisor:get_conf(agent_web_listener) of
				WebRecord when is_record(WebRecord, cpx_conf) ->
					lists:nth(1, WebRecord#cpx_conf.start_args);
				_Else2 ->
					undefined
			end,
			try list_to_integer(Webport) of
				OldWebPort  ->
					{struct, [{success, true}, {<<"message">>, <<"Nothing to do">>}]};
				M when M >= 1024, M =< 65535 ->
					cpx_supervisor:update_conf(agent_web_listener, agent_web_listener, start_link, [M]),
					{struct, [{success, true}, {<<"message">>, <<"Web Server enabled">>}]};
				_M ->
					{struct, [{success, false}, {<<"message">>, <<"Listen port out of range">>}]}
			catch
				error:badarg ->
					{struct, [{success, false}, {<<"message">>, <<"Listen port not a number">>}]}
			end
	end,
	{200, [], mochijson2:encode({struct, [{success, true}, {<<"results">>, [Tcpout, Webout]}]})};
api({agents, "modules", "get"}, ?COOKIE, _Post) ->
	Tcpout = case cpx_supervisor:get_conf(agent_tcp_listener) of
		undefined ->
			[{"agentModuleTCPListen", 1337}, {"agentModuleTCPListenEnabled", false}];
		Tcplist ->
			[Tcport] = Tcplist#cpx_conf.start_args,
			[{"agentModuleTCPListen", Tcport}, {"agentModuleTCPListenEnabled", true}]
	end,
	Webout = case cpx_supervisor:get_conf(agent_web_listener) of
		undefined ->
			[{"agentModuleWebListen", 5050}, {"agentModuleWebListenEnabled", false}];
		Weblist ->
			[Webport] = Weblist#cpx_conf.start_args,
			[{"agentModuleWebListen", Webport}, {"agentModuleWebListenEnabled", true}]
	end,
	Full = lists:append([Tcpout, Webout]),
	{200, [], mochijson2:encode({struct, [{success, true}, {<<"result">>, {struct, Full}}]})};

%% =====
%% agents -> profiles
%% =====
api({agents, "profiles", "get"}, ?COOKIE, _Post) ->
	Profiles = agent_auth:get_profiles(),
	Foreachprofile = fun({Pname, Pskills}) ->
		Agents = agent_auth:get_agents(Pname),
		{struct, [{<<"name">>, list_to_binary(Pname)}, {<<"type">>, <<"profile">>}, {<<"skills">>, encode_skills(Pskills)}, {<<"agents">>, encode_agents(Agents)}]}
	end,
	Items = lists:map(Foreachprofile, Profiles),
	Json = {struct, [{success, true}, {<<"items">>, Items}]},
	{200, [], mochijson2:encode(Json)};
api({agents, "profiles", Profile, "getskills"}, ?COOKIE, _Post) ->
	{_Profilename, Skillatoms} = agent_auth:get_profile(Profile),
	Encoded = encode_skills(Skillatoms),
	{200, [], mochijson2:encode({struct, [{success, true}, {<<"items">>, Encoded}]})};
api({agents, "profiles", "new"}, ?COOKIE, Post) ->
	Skillatoms = lists:map(fun(Skill) -> call_queue_config:skill_exists(Skill) end, proplists:get_all_values("skills", Post)),
	agent_auth:new_profile(proplists:get_value("name", Post), Skillatoms),
	{200, [], mochijson2:encode({struct, [{success, true}]})};
api({agents, "profiles", "Default", "update"}, {_Reflist, _Salt, _Login}, Post) ->
	case proplists:get_value("name", Post) of
		undefined ->
			Skillatoms = lists:map(fun(Skill) -> call_queue_config:skill_exists(Skill) end, proplists:get_all_values("skills", Post)),
			agent_auth:set_profile("Default", "Default", Skillatoms),
			{200, [], mochijson2:encode({struct, [{success, true}]})};
		_Else ->
			{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Default is a protected profile and cannot be renamed">>}]})}
	end;
api({agents, "profiles", Profile, "update"}, ?COOKIE, Post) ->
	Parseskills = fun(Skill) ->
		?CONSOLE("~p", [Skill]),
		case string:tokens(Skill, "{},") of
			["_brand", Brandname] ->
				{'_brand', Brandname};
			["_queue", Queuename] ->
				{'_queue', Queuename};
			[Skill] ->
				call_queue_config:skill_exists(Skill)
		end
	end,
	Skillatoms = lists:map(Parseskills, proplists:get_all_values("skills", Post)),
	agent_auth:set_profile(Profile, proplists:get_value("name", Post), Skillatoms),
	{200, [], mochijson2:encode({struct, [{success, true}]})};
api({agents, "profiles", "Default", "delete"}, ?COOKIE, _Post) ->
	{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Default is a protected profile and cannot be deleted">>}]})};
api({agents, "profiles", Profile, "delete"}, ?COOKIE, _Post) ->
	agent_auth:destroy_profile(Profile),
	{200, [], mochijson2:encode({struct, [{success, true}]})};

%% =====
%% agents -> agents
%% =====
api({agents, "agents", Agent, "get"}, ?COOKIE, _Post) ->
	{atomic, [Agentrec]} = agent_auth:get_agent(Agent),
	{200, [], mochijson2:encode({struct, [{success, true}, {<<"agent">>, encode_agent(Agentrec)}]})};
api({agents, "agents", Agent, "delete"}, ?COOKIE, _Post) ->
	agent_auth:destroy(Agent),
	{200, [], mochijson2:encode({struct, [{success, true}]})};
api({agents, "agents", Agent, "update"}, ?COOKIE, Post) ->
	{atomic, [_Agentrec]} = agent_auth:get_agent(Agent),
	{ok, Regex} = re:compile("^{(_\\w+),([-a-zA-Z0-9_ ]+)}$"),
	Postedskills = proplists:get_all_values("skills", Post),
	Convertskills = fun(Skill) ->
			case re:run(Skill, Regex, [{capture, all_but_first, list}]) of
			{match, [Atomstring, Expanded]} ->
				case call_queue_config:skill_exists(Atomstring) of
					undefined ->
						?CONSOLE("bad skill ~p : ~p", [Atomstring, Skill]),
						%erlang:error(badarg);
						[];
					Atom ->
						{Atom, Expanded}
				end;
			nomatch ->
				case call_queue_config:skill_exists(Skill) of
					undefined ->
						?CONSOLE("bad skill ~p", [Skill]),
						%erlang:error(badarg);
						[];
					Atom ->
						Atom
				end
		end
	end,
	Fixedskills = lists:flatten(lists:map(Convertskills, Postedskills)),
	?CONSOLE("~p", [Fixedskills]),
	Confirmpw = proplists:get_value("confirm", Post, {"notfilledin"}),
	case proplists:get_value("password", Post) of
		"" ->
			agent_auth:set_agent(Agent, 
				proplists:get_value("login", Post),
				Fixedskills,
				list_to_existing_atom(proplists:get_value("security", Post)),
				proplists:get_value("profile", Post));
		Confirmpw ->
			agent_auth:set_agent(Agent,
				proplists:get_value("login", Post),
				proplists:get_value("password", Post),
				Fixedskills,
				list_to_existing_atom(proplists:get_value("security", Post)),
				proplists:get_value("profile", Post))
	end,
	{200, [], mochijson2:encode({struct, [{success, true}]})};
api({agents, "agents", "new"}, ?COOKIE, Post) ->
	Confirmpw = proplists:get_value("confirm", Post, {"notfilledin"}),
	case proplists:get_value("password", Post) of
		"" ->
			erlang:error({badarg, proplists:get_value("password", Post)});
		Confirmpw ->
			Postedskills = proplists:get_all_values("skills", Post),
			{ok, Regex} = re:compile("^{(_\\w+),([-a-zA-Z0-9_ ]+)}$"),
			Convertskills = fun(Skill) ->
				case re:run(Skill, Regex, [{capture, all_but_first, list}]) of
					{match, [Atomstring, Expanded]} ->
						case call_queue_config:skill_exists(Atomstring) of
							undefined ->
								[];
								%erlang:error({badarg, Skill});
							Atom ->
								{Atom, Expanded}
						end;
					nomatch ->
						case call_queue_config:skill_exists(Skill) of
							undefined ->
								[];
								%erlang:error({badarg, Skill});
							Atom ->
								Atom
						end
				end
			end,
			Fixedskills = lists:flatten(lists:map(Convertskills, Postedskills)),
			agent_auth:add_agent(
				proplists:get_value("login", Post),
				Confirmpw,
				Fixedskills,
				list_to_existing_atom(proplists:get_value("security", Post)),
				proplists:get_value("profile", Post)),
				{200, [], mochijson2:encode({struct, [{success, true}]})}
	end;
	
%% =====
%% skills -> groups
%% =====
api({skills, "groups", "get"}, ?COOKIE, _Post) ->
	Skills = call_queue_config:get_skills(),
	Proplist = dict:to_list(encode_skills_with_groups(Skills)),
	Convert = fun({Group, Skillrecs}) ->
		{struct, [{<<"name">>, list_to_binary(Group)}, {<<"type">>, <<"group">>}, {<<"skills">>, encode_skills(Skillrecs)}]}
	end,
	Json = {struct, [{success, true}, {<<"items">>, lists:map(Convert, Proplist)}]},
	{200, [], mochijson2:encode(Json)};
api({skills, "groups", Group, "update"}, ?COOKIE, Post) ->
	?CONSOLE("Updating skill group ~p", [Group]),
	Newname = proplists:get_value("name", Post),
	call_queue_config:rename_skill_group(Group, Newname),
	{200, [], mochijson2:encode({struct, [{success, true}]})};
%api({skills, Profile}, {_Reflist, _Salt, _Login}, Post) ->
%	{_Profilename, Skillatoms} = agent_auth:get_profile(Profile),
%	Encoded = encode_skills(Skillatoms),
%	{200, [], mochijson2:encode({struct, [{success, true}, {<<"items">>, Encoded}]})};

%% =====
%% skills -> skill
%% =====
api({skills, "skill", "_queue", "expand"}, ?COOKIE, _Post) ->
	Queues = call_queue_config:get_queues(),
	F = fun(Qrec) ->
		list_to_binary(Qrec#call_queue.name)
	end,
	Converted = lists:map(F, Queues),
	{200, [], mochijson2:encode({struct, [{success, true}, {<<"items">>, Converted}]})};
api({skills, "skill", "_node", "expand"}, ?COOKIE, _Post) ->
	Nodes = [node() | nodes()],
	F = fun(Atom) ->
		L = atom_to_list(Atom),
		list_to_binary(L)
	end,
	Converted = lists:map(F, Nodes),
	{200, [], mochijson2:encode({struct, [{success, true}, {<<"items">>, Converted}]})};
api({skills, "skill", "_agent", "expand"}, {_Reflist, _Salt, _Login}, _Post) ->
	Agents = agent_auth:get_agents(),
	F = fun(Arec) ->
		list_to_binary(Arec#agent_auth.login)
	end,
	Converted = lists:map(F, Agents),
	{200, [], mochijson2:encode({struct, [{success, true}, {<<"items">>, Converted}]})};
api({skills, "skill", "_brand", "expand"}, ?COOKIE, _Post) ->
	Clients = call_queue_config:get_clients(),
	F = fun(Clientrec) ->
		list_to_binary(Clientrec#client.label)
	end,
	Converted = lists:map(F, Clients),
	{200, [], mochijson2:encode({struct, [{success, true}, {<<"items">>, Converted}]})};
api({skills, "skill", Skill, "update"}, ?COOKIE, Post) ->
	case call_queue_config:get_skill(Skill) of
		Skillrec when is_record(Skillrec, skill_rec) ->
			case Skillrec#skill_rec.protected of
				false ->
					Rec = #skill_rec{
						atom = Skillrec#skill_rec.atom,
						name = proplists:get_value("name", Post),
						description = proplists:get_value("description", Post),
						group = proplists:get_value("group", Post)},
					call_queue_config:set_skill(Skillrec#skill_rec.atom, Rec),
					{200, [], mochijson2:encode({struct, [{success, true}]})}
			end
	end;
api({skills, "skill", "new"}, ?COOKIE, Post) ->
	call_queue_config:new_skill(
		list_to_atom(proplists:get_value("atom", Post)),
		proplists:get_value("name", Post),
		proplists:get_value("description", Post),
		proplists:get_value("group", Post)
	),
	{200, [], mochijson2:encode({struct, [{success, true}]})};

%% =====
%% queues -> groups
%% =====

api({queues, "groups", "get"}, ?COOKIE, _Post) ->
	Groups = call_queue_config:get_queue_groups(),
	List = encode_queues_with_groups(Groups),
	Json = {struct, [{success, true}, {<<"items">>, List}]},
	{200, [], mochijson2:encode(Json)};
api({queues, "groups", Group, "get"}, ?COOKIE, _Post) ->
	{atomic, [Qgroup]} = call_queue_config:get_queue_group(Group),
	Jrecipe = encode_recipe(Qgroup#queue_group.recipe),
	Json = {struct, [
		{<<"name">>, list_to_binary(Qgroup#queue_group.name)},
		{<<"sort">>, Qgroup#queue_group.sort},
		{<<"protected">>, Qgroup#queue_group.protected},
		{<<"recipe">>, Jrecipe}
	]},
	{200, [], mochijson2:encode({struct, [{success, true}, {<<"queuegroup">>, Json}]})};
api({queues, "groups", Group, "update"}, ?COOKIE, Post) ->
	Newname = proplists:get_value("name", Post),
	Sort = list_to_integer(proplists:get_value("sort", Post)),
	Recipe = case proplists:get_value("recipe", Post) of
		"[]" ->
			[];
		Else ->
			decode_recipe(Else)
	end,
	call_queue_config:set_queue_group(Group, Newname, Sort, Recipe),
	{200, [], mochijson2:encode({struct, [{success, true}]})};
api({queues, "groups", "new"}, ?COOKIE, Post) ->
	Name = proplists:get_value("name", Post), 
	Sort = list_to_integer(proplists:get_value("sort", Post)),
	Recipe = case proplists:get_value("recipe", Post) of
		"[]" ->
			[];
		Else ->
			decode_recipe(Else)
	end,
	call_queue_config:new_queue_group(Name, Sort, Recipe),
	{200, [], mochijson2:encode({struct, [{success, true}]})};
api({queues, "groups", Group, "delete"}, ?COOKIE, _Post) ->
	case call_queue_config:destroy_queue_group(Group) of
		{atomic, ok} ->
			{200, [], mochijson2:encode({struct, [{success, true}]})};
		{atomic, {error, protected}} ->
			{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Group is protected and cannot be deleted">>}]})}
	end;
api({queues, "queue", Queue, "get"}, ?COOKIE, _Post) ->
	case call_queue_config:get_queue(Queue) of
		noexists ->
			{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"No such queue">>}]})};
		Queuerec ->
			Jqueue = encode_queue(Queuerec),
			{200, [], mochijson2:encode({struct, [{success, true}, {<<"queue">>, Jqueue}]})}
	end;
api({queues, "queue", Queue, "update"}, ?COOKIE, Post) ->
	Recipe = decode_recipe(proplists:get_value("recipe", Post)),
	Weight = list_to_integer(proplists:get_value("weight", Post)),
	Name = proplists:get_value("name", Post),
	Postedskills = proplists:get_all_values("skills", Post),
	Atomizedskills = lists:map(fun(Skill) -> call_queue_config:skill_exists(Skill) end, Postedskills),
	Group = proplists:get_value("group", Post),
	Qrec = #call_queue{
		name = Name,
		weight = Weight,
		skills = Atomizedskills,
		recipe = Recipe,
		group = Group
	},
	call_queue_config:set_queue(Queue, Qrec),
	{200, [], mochijson2:encode({struct, [{success, true}]})};
api({queues, "queue", Queue, "delete"}, ?COOKIE, _Post) ->
	call_queue_config:destroy_queue(Queue),
	{200, [], mochijson2:encode({struct, [{success, true}]})};
api({queues, "queue", "new"}, ?COOKIE, Post) ->
	Postedskills = proplists:get_all_values("skills", Post),
	Atomizedskills = lists:map(fun(Skill) -> call_queue_config:skill_exists(Skill) end, Postedskills),
	Recipe = decode_recipe(proplists:get_value("recipe", Post)),
	Weight = list_to_integer(proplists:get_value("weight", Post)),
	Name = proplists:get_value("name", Post),
	Group = proplists:get_value("group", Post),
	Qrec = #call_queue{
		name = Name,
		weight = Weight,
		skills = Atomizedskills,
		recipe = Recipe,
		group = Group
	},
	call_queue_config:new_queue(Qrec),
	{200, [], mochijson2:encode({struct, [{success, true}]})};
	
%% =====
%% media -> *
%% =====
api({medias, "poll"}, ?COOKIE, _Post) ->
	Nodes = [node() | nodes()],
	F = fun(Node) ->
		{Node, [{freeswitch_media_manager, rpc:call(Node, cpx_supervisor, get_conf, [freeswitch_media_manager], 2000)}]}
	end,
	Rpcs = lists:map(F, Nodes),
	Json = encode_medias(Rpcs, []),
	{200, [], mochijson2:encode({struct, [{success, true}, {<<"identifier">>, <<"id">>}, {<<"label">>, <<"name">>}, {<<"items">>, Json}]})};
api({medias, Node, "freeswitch_media_manager", "update"}, ?COOKIE, Post) ->
	case proplists:get_value("enabled", Post) of
		undefined ->
			cpx_supervisor:destroy(freeswitch_media_manager),
			{200, [], mochijson2:encode({struct, [{success, true}]})};
		_Else ->
			Args = [list_to_atom(proplists:get_value("cnode", Post)), proplists:get_value("domain", Post, "")],
			Start = start_link,
			Atomnode = list_to_existing_atom(Node),
			rpc:call(Atomnode, cpx_supervisor, update_conf, [freeswitch_media_manager, freeswitch_media_manager, Start, Args], 2000),
			{200, [], mochijson2:encode({struct, [{success, true}]})}
	end;
api({medias, Node, "freeswitch_media_manager", "get"}, ?COOKIE, _Post) ->
	Anode = list_to_existing_atom(Node),
	case rpc:call(Anode, cpx_supervisor, get_conf, [freeswitch_media_manager]) of
		undefined ->
			Json = {struct, [
				{success, true},
				{<<"enabled">>, false}
			]},
			{200, [], mochijson2:encode(Json)};
		Rec when is_record(Rec, cpx_conf) ->
			[Cnode, Domain] = Rec#cpx_conf.start_args,
			Json = {struct, [
				{success, true},
				{<<"enabled">>, true},
				{<<"cnode">>, list_to_binary(atom_to_list(Cnode))},
				{<<"domain">>, list_to_binary(Domain)}
			]},
			{200, [], mochijson2:encode(Json)}
	end.
	
% path spec:
% /basiccommand
% /section/subsection/action
% /section/subsection/item/action
%
% So, this means to update the modules for agents:
% /agents/modules/update
% but to update an agent profile:
% /agents/profiles/profilename/update
parse_path(Path) ->
	case Path of
		"/" ->
			{file, {"index.html", "www/admin/"}};
		"/getsalt" ->
			{api, getsalt};
		"/login" ->
			{api, login};
		"/logout" ->
			{api, logout};
		"/checkcookie" ->
			{api, checkcookie};
		_Other ->
			% section/action (params in post data)
			case util:string_split(Path, "/") of
				["", "agents", "modules", Action] ->
					{api, {agents, "modules", Action}};
				["", "agents", "profiles", Action] ->
					{api, {agents, "profiles", Action}};
				["", "agents", "profiles", Profile, Action] ->
					{api, {agents, "profiles", Profile, Action}};
				["", "agents", "agents", Action] ->
					{api, {agents, "agents", Action}};
				["", "agents", "agents", Agent, Action] ->
					{api, {agents, "agents", Agent, Action}};
				["", "skills", "groups", Action] ->
					{api, {skills, "groups", Action}};
				["", "skills", "groups", Group, Action] ->
					{api, {skills, "groups", Group, Action}};
				["", "skills", "skill", Action] ->
					{api, {skills, "skill", Action}};
				["", "skills", "skill", Skill, Action] ->
					{api, {skills, "skill", Skill, Action}};
				["", "queues", "groups", Action] ->
					{api, {queues, "groups", Action}};
				["", "queues", "groups", Group, Action] ->
					{api, {queues, "groups", Group, Action}};
				["", "queues", "queue", Queue, Action] ->
					{api, {queues, "queue", Queue, Action}};
				["", "queues", "queue", Action] ->
					{api, {queues, "queue", Action}};
				["", "medias", Action] ->
					{api, {medias, Action}};
				["", "medias", Node, Media, Action] ->
					{api, {medias, Node, Media, Action}};
				_Allothers ->
					case filelib:is_regular(string:concat("www/admin", Path)) of
						true ->
							{file, {string:strip(Path, left, $/), "www/admin/"}};
						false ->
							{file, {string:strip(Path, left, $/), "www/contrib/"}}
					end
			end
	end.

check_cookie([]) ->
	badcookie;
check_cookie(Allothers) ->
	case proplists:get_value("cpx_management", Allothers) of
		undefined ->
			?CONSOLE("Cookie bad due to no cpx_managmenet.  ~p", [Allothers]),
			badcookie;
		Reflist ->
			case ets:lookup(cpx_management_logins, Reflist) of
				[] ->
					?CONSOLE("Cookie bad reflist not in ets.  ~p", [Allothers]),
					badcookie;
				[{Reflist, Salt, Login}] ->
					{Reflist, Salt, Login}
			end
	end.

encode_skill(Atom) when is_atom(Atom), Atom =/= undefined ->
	Skill = call_queue_config:get_skill(Atom),
	encode_skill(Skill);
encode_skill({Atom, Value}) when is_atom(Atom), is_list(Value) ->
	encode_skill({Atom, list_to_binary(Value)});
encode_skill({Atom, Value}) ->
	Skill = call_queue_config:get_skill(Atom),
	{struct, [{name, list_to_binary(Skill#skill_rec.name)},
		{type, skill}, {atom, Skill#skill_rec.atom},
		{description, list_to_binary(Skill#skill_rec.description)},
		{protected, Skill#skill_rec.protected},
		{group, list_to_binary(Skill#skill_rec.group)},
		{expanded, Value}]};
encode_skill(Skill) when is_record(Skill, skill_rec) ->
	{struct, [{name, list_to_binary(Skill#skill_rec.name)},
		{type, skill}, {atom, Skill#skill_rec.atom},
		{description, list_to_binary(Skill#skill_rec.description)},
		{group, list_to_binary(Skill#skill_rec.group)},
		{protected, Skill#skill_rec.protected}]};
encode_skill(_) ->
	[].


encode_skills(Skills) ->
	encode_skills(Skills, []).

encode_skills([], Acc) ->
	lists:flatten(lists:reverse(Acc));
encode_skills([Skill|Skills], Acc) ->
	Head = encode_skill(Skill),
	encode_skills(Skills, [Head | Acc]).

encode_skills_with_groups([]) ->
	[];
encode_skills_with_groups(Skills) ->
	encode_skills_with_groups(Skills, dict:new()).

encode_skills_with_groups([], Acc) ->
	Acc;
encode_skills_with_groups([Skill | Skills], Acc) ->
	case dict:find(Skill#skill_rec.group, Acc) of
		error ->
			Sgroups = [];
		{ok, Sgroups} ->
			Sgroups
	end,
	Newacc = dict:store(Skill#skill_rec.group, [Skill | Sgroups], Acc),
	encode_skills_with_groups(Skills, Newacc).
	
%	ASkill = lists:nth(1, Group),
%	[{struct, [{name, list_to_binary(ASkill#skill_rec.group)},
%			{type, group},
%			{children, encode_skills(Group)}]} | encode_skills_with_groups(Groups)].

encode_queue(Queue) ->
	{struct, [{name, list_to_binary(Queue#call_queue.name)},
			{type, queue}, {weight, Queue#call_queue.weight},
			{skills, Queue#call_queue.skills},
			{recipe, encode_recipe(Queue#call_queue.recipe)},
			{group, list_to_binary(Queue#call_queue.group)}]}.

encode_queues(Queues) ->
	encode_queues(Queues, []).

encode_queues([], Acc) ->
	lists:reverse(Acc);
encode_queues([Queue | Queues], Acc) ->
	Head = encode_queue(Queue),
	encode_queues(Queues, [Head | Acc]).

encode_queues_with_groups(Groups) ->
	encode_queues_with_groups(Groups, []).

encode_queues_with_groups([], Acc) ->
	lists:reverse(Acc);
encode_queues_with_groups([Group | Groups], Acc) ->
	Queues = call_queue_config:get_queues(Group#queue_group.name),
	Head = {struct, [
		{name, list_to_binary(Group#queue_group.name)},
		{recipe, encode_recipe(Group#queue_group.recipe)},
		{sort, Group#queue_group.sort},
		{protected, Group#queue_group.protected},
		{<<"type">>, <<"group">>},
		{queues, encode_queues(Queues)}]},
	encode_queues_with_groups(Groups, [Head | Acc]).
	
encode_agents([]) ->
	[];
encode_agents([Agent|Agents]) ->
	[encode_agent(Agent) | encode_agents(Agents)].

encode_agent(Agentrec) when is_record(Agentrec, agent_auth) ->
	{struct, [
		{name, list_to_binary(Agentrec#agent_auth.login)},
		{<<"type">>, <<"agent">>},
		{login, list_to_binary(Agentrec#agent_auth.login)},
		{skills, encode_skills(Agentrec#agent_auth.skills)},
		{securitylevel, Agentrec#agent_auth.securitylevel},
		{integrated, Agentrec#agent_auth.integrated},
		{profile, list_to_binary(Agentrec#agent_auth.profile)}
	]}.
	
decode_recipe([Test | Tail]) when is_tuple(Test) ->
	decode_recipe([Test | Tail], []);
decode_recipe("[]") ->
	[];
decode_recipe(Json) ->
	Structed = mochijson2:decode(Json),
	decode_recipe(Structed).

decode_recipe([], Acc) ->
	lists:reverse(Acc);
decode_recipe([{struct, Proplist} | Tail], Acc) ->
	Action = case proplists:get_value(<<"action">>, Proplist) of
		<<"add_skills">> ->
			add_skills;
		<<"remove_skills">> ->
			remove_skills;
		<<"set_priority">> ->
			set_priority;
		<<"prioritize">> ->
			prioritize;
		<<"deprioritize">> ->
			deprioritize;
		<<"voicemail">> ->
			voicemail;
		<<"announce">> ->
			announce;
		<<"add_recipe">> ->
			add_recipe
	end,
	Args = decode_recipe_args(Action, proplists:get_value(<<"arguments">>, Proplist)),
	Runs = case proplists:get_value(<<"runs">>, Proplist) of
		<<"run_once">> ->
			run_once;
		<<"run_many">> ->
			run_many
	end,
	Conditions = decode_recipe_conditions(proplists:get_value(<<"conditions">>, Proplist)),
	decode_recipe(Tail, [{Conditions, Action, Args, Runs} | Acc]).

decode_recipe_args(add_skills, Args) ->
	decode_recipe_args(remove_skills, Args);
decode_recipe_args(remove_skills, Args) ->
	F = fun(Bin) ->
		case call_queue_config:skill_exists(binary_to_list(Bin)) of
			undefined ->
				erlang:error(bararg, Bin);
			Atom ->
				Atom
		end
	end,
	lists:map(F, Args);
decode_recipe_args(set_priority, Args) ->
	list_to_integer(binary_to_list(Args));
decode_recipe_args(prioritize, _Args) ->
	[];
decode_recipe_args(deprioritize, _Args) ->
	[];
decode_recipe_args(voicemail, Args) ->
	binary_to_list(Args);
decode_recipe_args(announce, Args) ->
	binary_to_list(Args);
decode_recipe_args(add_recipe, _Args) ->
	% TODO add support
	[].

decode_recipe_conditions(Conds) ->
	decode_recipe_conditions(Conds, []).

decode_recipe_conditions([], Acc) ->
	lists:reverse(Acc);
decode_recipe_conditions([{struct, Props} | Tail], Acc) ->
	Cond = proplists:get_value(<<"property">>, Props),
	Comp = case proplists:get_value(<<"comparison">>, Props) of
		<<"=">> ->
			'=';
		<<">">> ->
			'>';
		<<"<">> ->
			'<'
	end,
	Val = case proplists:get_value(<<"value">>, Props) of
		V when is_integer(V) ->
			V;
		V when is_binary(V) ->
			list_to_integer(binary_to_list(V));
		V ->
			V
	end,
	Tuple = case {Cond, Comp, Val} of
		{<<"ticks">>, '=', Val} ->
			{ticks, Val};
		{<<"eligible_agents">>, Comp, Val} ->
			{eligible_agents, Comp, Val};
		{<<"agents_avail">>, Comp, Val} ->
			{available_agents, Comp, Val};
		{<<"queue_position">>, Comp, Val} ->
			{queue_position, Comp, Val};
		{<<"calls_queued">>, Comp, Val} ->
			{calls_queued, Comp, Val}
	end,
	decode_recipe_conditions(Tail, [Tuple | Acc]).	
	
encode_recipe(Recipe) ->
	encode_recipe_steps(Recipe).

encode_recipe_steps(Steps) ->
	encode_recipe_steps(Steps, []).

encode_recipe_steps([], Acc) ->
	lists:reverse(Acc);
encode_recipe_steps([Step | Tail], Acc) ->
	Jstep = encode_recipe_step(Step),
	encode_recipe_steps(Tail, [Jstep | Acc]).

encode_recipe_step({Conditions, Action, Args, Runs}) ->
	Jcond = encode_recipe_conditions(Conditions),
	Jargs = case Action of
		add_skills ->
			Args;
		remove_skills ->
			Args;
		set_priority ->
			Args;
		prioritize ->
			<<"">>;
		deprioritize ->
			<<"">>;
		voicemail ->
			<<"">>;
		announce ->
			list_to_binary(Args);
		add_recipe ->
			% TODO:  more encoding
			<<"">>
	end,
	{struct, [
		{<<"conditions">>, Jcond},
		{<<"action">>, Action},
		{<<"arguments">>, Jargs},
		{<<"runs">>, Runs}
	]}.

encode_recipe_conditions(Conditions) ->
	encode_recipe_conditions(Conditions, []).

encode_recipe_conditions([], Acc) ->
	lists:reverse(Acc);
encode_recipe_conditions([{ticks, Num} | Tail], Acc) ->
	encode_recipe_conditions([{ticks, '=', Num} | Tail], Acc);
encode_recipe_conditions([{Prop, Comp, Num} | Tail], Acc) ->
	Jcond = {struct, [
		{<<"property">>, Prop},
		{<<"comparison">>, Comp},
		{<<"value">>, Num}
	]},
	encode_recipe_conditions(Tail, [Jcond | Acc]).

encode_medias([], Acc) ->
	lists:reverse(Acc);
encode_medias([{Node, Medias} | Tail], Acc) ->
	Json = {struct, [
		{<<"name">>, list_to_binary(atom_to_list(Node))},
		{<<"type">>, <<"node">>},
		{<<"id">>, list_to_binary(atom_to_list(Node))},
		{<<"medias">>, encode_medias_confs(Node, Medias, [])}
	]},
	encode_medias(Tail, [Json | Acc]).

encode_medias_confs(_Node, [], Acc) ->
	lists:reverse(Acc);
encode_medias_confs(Node, [{Mod, Conf} | Tail], Acc) when is_record(Conf, cpx_conf) ->
	Json = {struct, [
		{<<"name">>, list_to_binary(atom_to_list(Conf#cpx_conf.module_name))},
		{<<"enabled">>, true},
		{<<"type">>, <<"conf">>},
		{<<"id">>, list_to_binary(atom_to_list(Node) ++ "/" ++ atom_to_list(Mod))},
		{<<"mediatype">>, list_to_binary(atom_to_list(Mod))},
		{<<"start">>, list_to_binary(atom_to_list(Conf#cpx_conf.start_function))},
		{<<"args">>, encode_media_args(Conf#cpx_conf.start_args, [])},
		{<<"node">>, list_to_binary(atom_to_list(Node))}
	]},
	encode_medias_confs(Node, Tail, [Json | Acc]);
encode_medias_confs(Node, [{Mod, undefined} | Tail], Acc) ->
	Json = {struct, [
		{<<"name">>, list_to_binary(atom_to_list(Mod))},
		{<<"enabled">>, false},
		{<<"mediatype">>, list_to_binary(atom_to_list(Mod))},
		{<<"type">>, <<"conf">>},
		{<<"id">>, list_to_binary(atom_to_list(Node) ++ "/" ++ atom_to_list(Mod))},
		{<<"node">>, list_to_binary(atom_to_list(Node))}
	]},
	encode_medias_confs(Node, Tail, [Json | Acc]).

encode_media_args([], Acc) ->
	lists:reverse(Acc);
encode_media_args([Arg | Tail], Acc) when is_list(Arg) ->
	encode_media_args(Tail, [list_to_binary(Arg) | Acc]);
encode_media_args([Arg | Tail], Acc) when is_atom(Arg) ->
	encode_media_args(Tail, [list_to_binary(atom_to_list(Arg)) | Acc]);
encode_media_args([Arg | Tail], Acc) when is_binary(Arg) ->
	encode_media_args(Tail, [Arg, Acc]).