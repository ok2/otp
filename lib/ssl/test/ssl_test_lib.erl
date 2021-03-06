%%
%% %CopyrightBegin%
%% 
%% Copyright Ericsson AB 2008-2009. All Rights Reserved.
%% 
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%% 
%% %CopyrightEnd%
%%

%%
-module(ssl_test_lib).

-include("test_server.hrl").
-include("test_server_line.hrl").

%% Note: This directive should only be used in test suites.
-compile(export_all).


timetrap(Time) ->
    Mul = try 
	      test_server:timetrap_scale_factor()
	  catch _:_ -> 1 end,
    test_server:timetrap(1000+Time*Mul).

%% For now always run locally
run_where(_) ->
    ClientNode = node(),
    ServerNode = node(),
    {ok, Host} = rpc:call(ServerNode, inet, gethostname, []),
    {ClientNode, ServerNode, Host}.

run_where(_, ipv6) ->
    ClientNode = node(),
    ServerNode = node(),
    {ok, Host} = rpc:call(ServerNode, inet, gethostname, []),
    {ClientNode, ServerNode, Host}.

node_to_hostip(Node) ->
    [_ , Host] = string:tokens(atom_to_list(Node), "@"),
    {ok, Address} = inet:getaddr(Host, inet),
    Address.

start_server(Args) ->
    spawn_link(?MODULE, run_server, [Args]).

run_server(Opts) ->
    Node = proplists:get_value(node, Opts),
    Port = proplists:get_value(port, Opts),
    Options = proplists:get_value(options, Opts),
    Pid = proplists:get_value(from, Opts),
    test_server:format("ssl:listen(~p, ~p)~n", [Port, Options]),
    {ok, ListenSocket} = rpc:call(Node, ssl, listen, [Port, Options]),
    case Port of
	0 ->
	    {ok, {_, NewPort}} = ssl:sockname(ListenSocket),	 
	    Pid ! {self(), {port, NewPort}};
	_ ->
	    ok
    end,
    run_server(ListenSocket, Opts).

run_server(ListenSocket, Opts) ->
    Node = proplists:get_value(node, Opts),
    Pid = proplists:get_value(from, Opts),
    test_server:format("ssl:transport_accept(~p)~n", [ListenSocket]),
    {ok, AcceptSocket} = rpc:call(Node, ssl, transport_accept, 
				  [ListenSocket]),    
    test_server:format("ssl:ssl_accept(~p)~n", [AcceptSocket]),
    ok = rpc:call(Node, ssl, ssl_accept, [AcceptSocket]),
    {Module, Function, Args} = proplists:get_value(mfa, Opts),
    test_server:format("Server: apply(~p,~p,~p)~n", 
		       [Module, Function, [AcceptSocket | Args]]),
    case rpc:call(Node, Module, Function, [AcceptSocket | Args]) of
	no_result_msg ->
	    ok;
	Msg ->
	    Pid ! {self(), Msg}
    end,
    receive 
	listen ->
	    run_server(ListenSocket, Opts);
	close ->
	    ok = rpc:call(Node, ssl, close, [AcceptSocket])
    end.

start_client(Args) ->
    spawn_link(?MODULE, run_client, [Args]).

run_client(Opts) ->
    Node = proplists:get_value(node, Opts),
    Host = proplists:get_value(host, Opts),
    Port = proplists:get_value(port, Opts),
    Pid = proplists:get_value(from, Opts),
    Options = proplists:get_value(options, Opts),
    test_server:format("ssl:connect(~p, ~p, ~p)~n", [Host, Port, Options]),
    case rpc:call(Node, ssl, connect, [Host, Port, Options]) of
	{ok, Socket} ->
	    test_server:format("Client: connected~n", []), 
	    case proplists:get_value(port, Options) of
		0 ->
		    {ok, {_, NewPort}} = ssl:sockname(Socket),	 
		    Pid ! {self(), {port, NewPort}};
		_ ->
		    ok
	    end,
	    {Module, Function, Args} = proplists:get_value(mfa, Opts),
	    test_server:format("Client: apply(~p,~p,~p)~n", 
			       [Module, Function, [Socket | Args]]),
	    case rpc:call(Node, Module, Function, [Socket | Args]) of
		no_result_msg ->
		    ok;
		Msg ->
		    Pid ! {self(), Msg}
	    end,
	    receive 
		close ->
		    ok = rpc:call(Node, ssl, close, [Socket])
	    end;
	{error, Reason} ->
	    test_server:format("Client: connection failed: ~p ~n", [Reason]), 
	       Pid ! {self(), {error, Reason}}
    end.

close(Pid) ->
    Pid ! close.

check_result(Server, ServerMsg, Client, ClientMsg) -> 
    receive 
	{Server, ServerMsg} -> 
	    receive 
		{Client, ClientMsg} ->
		    ok;
		Unexpected ->
		    Reason = {{expected, {Client, ClientMsg}}, 
			      {got, Unexpected}},
		    test_server:fail(Reason)
	    end;
	{Client, ClientMsg} -> 
	    receive 
		{Server, ServerMsg} ->
		    ok;
		Unexpected ->
		    Reason = {{expected, {Server, ClientMsg}}, 
			      {got, Unexpected}},
		    test_server:fail(Reason)
	    end;
	{Port, {data,Debug}} when is_port(Port) ->
	    io:format("openssl ~s~n",[Debug]),
	    check_result(Server, ServerMsg, Client, ClientMsg);

	Unexpected ->
	    Reason = {{expected, {Client, ClientMsg}},
		      {expected, {Server, ServerMsg}}, {got, Unexpected}},
	    test_server:fail(Reason)
    end.

check_result(Pid, Msg) -> 
    receive 
	{Pid, Msg} -> 
	    ok;
	{Port, {data,Debug}} when is_port(Port) ->
	    io:format("openssl ~s~n",[Debug]),
	    check_result(Pid,Msg);
	Unexpected ->
	    Reason = {{expected, {Pid, Msg}}, 
		      {got, Unexpected}},
	    test_server:fail(Reason)
    end.

wait_for_result(Server, ServerMsg, Client, ClientMsg) -> 
    receive 
	{Server, ServerMsg} -> 
	    receive 
		{Client, ClientMsg} ->
		    ok;
		Unexpected ->
		    Unexpected
	    end;
	{Client, ClientMsg} -> 
	    receive 
		{Server, ServerMsg} ->
		    ok;
		Unexpected ->
		    Unexpected
	    end;
	{Port, {data,Debug}} when is_port(Port) ->
	    io:format("openssl ~s~n",[Debug]),
	    wait_for_result(Server, ServerMsg, Client, ClientMsg);
	Unexpected ->
	    Unexpected
    end.


wait_for_result(Pid, Msg) -> 
    receive 
	{Pid, Msg} -> 
	    ok;
	{Port, {data,Debug}} when is_port(Port) ->
	    io:format("openssl ~s~n",[Debug]),
	    wait_for_result(Pid,Msg);
	Unexpected ->
	    Unexpected
    end.

cert_options(Config) ->
    ClientCaCertFile = filename:join([?config(priv_dir, Config), 
				      "client", "cacerts.pem"]),
    ClientCertFile = filename:join([?config(priv_dir, Config), 
				    "client", "cert.pem"]),
    ServerCaCertFile = filename:join([?config(priv_dir, Config), 
				      "server", "cacerts.pem"]),
    ServerCertFile = filename:join([?config(priv_dir, Config), 
				    "server", "cert.pem"]),
    ServerKeyFile = filename:join([?config(priv_dir, Config), 
			     "server", "key.pem"]),
    ClientKeyFile = filename:join([?config(priv_dir, Config), 
			     "client", "key.pem"]),
    ServerKeyCertFile = filename:join([?config(priv_dir, Config), 
				       "server", "keycert.pem"]),
    ClientKeyCertFile = filename:join([?config(priv_dir, Config), 
				       "client", "keycert.pem"]),

    BadCaCertFile = filename:join([?config(priv_dir, Config), 
				   "badcacert.pem"]),
    BadCertFile = filename:join([?config(priv_dir, Config), 
				   "badcert.pem"]),
    BadKeyFile = filename:join([?config(priv_dir, Config), 
			      "badkey.pem"]),
    [{client_opts, [{ssl_imp, new}]}, 
     {client_verification_opts, [{cacertfile, ClientCaCertFile}, 
				{certfile, ClientCertFile},  
				{keyfile, ClientKeyFile},
				{ssl_imp, new}]}, 
     {server_opts, [{ssl_imp, new},{reuseaddr, true}, 
		    {certfile, ServerCertFile}, {keyfile, ServerKeyFile}]},
     {server_verification_opts, [{ssl_imp, new},{reuseaddr, true}, 
		    {cacertfile, ServerCaCertFile},
		    {certfile, ServerCertFile}, {keyfile, ServerKeyFile}]},
     {client_kc_opts, [{certfile, ClientKeyCertFile},  {ssl_imp, new}]}, 
     {server_kc_opts, [{ssl_imp, new},{reuseaddr, true}, 
		       {certfile, ServerKeyCertFile}]},
     {client_bad_ca, [{cacertfile, BadCaCertFile}, 
		      {certfile, ClientCertFile},
		      {keyfile, ClientKeyFile},
		      {ssl_imp, new}]},
     {client_bad_cert, [{cacertfile, ClientCaCertFile},	    
			{certfile, BadCertFile},  
			{keyfile, ClientKeyFile},
			{ssl_imp, new}]},
     {server_bad_ca, [{ssl_imp, new},{cacertfile, BadCaCertFile},
		      {certfile, ServerCertFile}, 
		      {keyfile, ServerKeyFile}]},
     {server_bad_cert, [{ssl_imp, new},{cacertfile, ServerCaCertFile},
			{certfile, BadCertFile}, {keyfile, ServerKeyFile}]},
     {server_bad_key, [{ssl_imp, new},{cacertfile, ServerCaCertFile},
		       {certfile, ServerCertFile}, {keyfile, BadKeyFile}]}
     | Config].


start_upgrade_server(Args) ->
    spawn_link(?MODULE, run_upgrade_server, [Args]).

run_upgrade_server(Opts) ->
    Node = proplists:get_value(node, Opts),
    Port = proplists:get_value(port, Opts),
    TimeOut = proplists:get_value(timeout, Opts, infinity),
    TcpOptions = proplists:get_value(tcp_options, Opts),
    SslOptions = proplists:get_value(ssl_options, Opts),
    Pid = proplists:get_value(from, Opts),
   
    test_server:format("gen_tcp:listen(~p, ~p)~n", [Port, TcpOptions]),
    {ok, ListenSocket} = rpc:call(Node, gen_tcp, listen, [Port, TcpOptions]),
    
    case Port of
	0 ->
	    {ok, {_, NewPort}} = inet:sockname(ListenSocket),	 
	    Pid ! {self(), {port, NewPort}};
	_ ->
	    ok
    end,

    test_server:format("gen_tcp:accept(~p)~n", [ListenSocket]),
    {ok, AcceptSocket} = rpc:call(Node, gen_tcp, accept, [ListenSocket]),
     
    {ok, SslAcceptSocket} = case TimeOut of 
				infinity ->
				    test_server:format("ssl:ssl_accept(~p, ~p)~n", 
						       [AcceptSocket, SslOptions]),   
				    rpc:call(Node, ssl, ssl_accept, 
					     [AcceptSocket, SslOptions]);
				_ ->
				    test_server:format("ssl:ssl_accept(~p, ~p, ~p)~n", 
						       [AcceptSocket, SslOptions, TimeOut]),   
				    rpc:call(Node, ssl, ssl_accept, 
					     [AcceptSocket, SslOptions, TimeOut])
			    end,
    {Module, Function, Args} = proplists:get_value(mfa, Opts),
    Msg = rpc:call(Node, Module, Function, [SslAcceptSocket | Args]),
    Pid ! {self(), Msg},
    receive 
	close ->
	    ok = rpc:call(Node, ssl, close, [SslAcceptSocket])
    end.

start_upgrade_client(Args) ->
    spawn_link(?MODULE, run_upgrade_client, [Args]).

run_upgrade_client(Opts) ->
    Node = proplists:get_value(node, Opts),
    Host = proplists:get_value(host, Opts),
    Port = proplists:get_value(port, Opts),
    Pid = proplists:get_value(from, Opts),
    TcpOptions = proplists:get_value(tcp_options, Opts),
    SslOptions = proplists:get_value(ssl_options, Opts),
    
    test_server:format("gen_tcp:connect(~p, ~p, ~p)~n", 
		       [Host, Port, TcpOptions]),
    {ok, Socket} = rpc:call(Node, gen_tcp, connect, [Host, Port, TcpOptions]),
    
    case proplists:get_value(port, Opts) of
	0 ->
	    {ok, {_, NewPort}} = inet:sockname(Socket),	 
	    Pid ! {self(), {port, NewPort}};
	_ ->
	    ok
    end,

    test_server:format("ssl:connect(~p, ~p)~n", [Socket, SslOptions]),
    {ok, SslSocket} = rpc:call(Node, ssl, connect, [Socket, SslOptions]),

    {Module, Function, Args} = proplists:get_value(mfa, Opts),
    test_server:format("apply(~p, ~p, ~p)~n", 
		       [Module, Function, [SslSocket | Args]]),
    Msg = rpc:call(Node, Module, Function, [SslSocket | Args]),
    Pid ! {self(), Msg},
    receive 
	close ->
	    ok = rpc:call(Node, ssl, close, [SslSocket])
    end.

start_server_error(Args) ->
    spawn_link(?MODULE, run_server_error, [Args]).

run_server_error(Opts) ->
    Node = proplists:get_value(node, Opts),
    Port = proplists:get_value(port, Opts),
    Options = proplists:get_value(options, Opts),
    Pid = proplists:get_value(from, Opts),
    test_server:format("ssl:listen(~p, ~p)~n", [Port, Options]),
    case rpc:call(Node, ssl, listen, [Port, Options]) of
	{ok, ListenSocket} ->
	    test_server:sleep(2000), %% To make sure error_client will
	    %% get {error, closed} and not {error, connection_refused}
	    test_server:format("ssl:transport_accept(~p)~n", [ListenSocket]),
	    case rpc:call(Node, ssl, transport_accept, [ListenSocket]) of
		{error, _} = Error ->
		    Pid ! {self(), Error};
		{ok, AcceptSocket} ->
		    test_server:format("ssl:ssl_accept(~p)~n", [AcceptSocket]),
		    Error = rpc:call(Node, ssl, ssl_accept, [AcceptSocket]),
		    Pid ! {self(), Error}
	    end;
	Error ->
	    Pid ! {self(), Error}
    end.

start_client_error(Args) ->
    spawn_link(?MODULE, run_client_error, [Args]).

run_client_error(Opts) ->
    Node = proplists:get_value(node, Opts),
    Host = proplists:get_value(host, Opts),
    Port = proplists:get_value(port, Opts),
    Pid = proplists:get_value(from, Opts),
    Options = proplists:get_value(options, Opts),
    test_server:format("ssl:connect(~p, ~p, ~p)~n", [Host, Port, Options]),
    Error = rpc:call(Node, ssl, connect, [Host, Port, Options]),
    Pid ! {self(), Error}.

inet_port(Pid) when is_pid(Pid)->
    receive
	{Pid, {port, Port}} ->
	    Port
    end;

inet_port(Node) ->
    {Port, Socket} = do_inet_port(Node),
    rpc:call(Node, gen_tcp, close, [Socket]),
    Port.

do_inet_port(Node) ->
    {ok, Socket} = rpc:call(Node, gen_tcp, listen, [0, [{reuseaddr, true}]]),
    {ok, Port} = rpc:call(Node, inet, port, [Socket]),
    {Port, Socket}.

no_result(_) ->
    no_result_msg.
