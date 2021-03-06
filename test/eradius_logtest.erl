-module(eradius_logtest).

-export([start/0, test/0, radius_request/3, validate_arguments/1, test_client/0, test_client/1, test_proxy/0, test_proxy/1]).
-import(eradius_lib, [get_attr/2]).

-include_lib("eradius/include/eradius_lib.hrl").
-include_lib("eradius/include/eradius_dict.hrl").
-include_lib("eradius/include/dictionary.hrl").
-include_lib("eradius/include/dictionary_3gpp.hrl").

-define(ALLOWD_USERS, [undefined, <<"user">>, <<"user@domain">>, <<"proxy_test">>]).
-define(SECRET, <<"secret">>).
-define(SECRET2, <<"proxy_secret">>).
-define(SECRET3, <<"test_secret">>).

-define(CLIENT_REQUESTS_COUNT, 1).
-define(CLIENT_PROXY_REQUESTS_COUNT, 4).

start() ->
    application:load(eradius),
    ProxyConfig = [{default_route, {{127, 0, 0, 1}, 1813, ?SECRET}},
                   {options, [{type, realm}, {strip, true}, {separator, "@"}]},
                   {routes, [{"test", {{127, 0, 0, 1}, 1815, ?SECRET3}}
                            ]}
                  ],
    Config = [{radius_callback, eradius_logtest},
              {servers, [{root,  {"127.0.0.1", [1812, 1813]}},
                         {test,  {"127.0.0.1", [1815]}},
                         {proxy, {"127.0.0.1", [11812, 11813]}}
                        ]},
              {session_nodes, [node()]},
              {root, [
                       { {eradius_logtest, "root", [] }, [{"127.0.0.1/24", ?SECRET}] }
              ]},
              {test, [
                       { {eradius_logtest, "test", [] }, [{"127.0.0.1", ?SECRET3}] }
              ]},
              {proxy, [
                       { {eradius_proxy, "proxy", ProxyConfig }, [{"127.0.0.1", ?SECRET2}] }
              ]}
             ],
    [application:set_env(eradius, Key, Value) || {Key, Value} <- Config],
    {ok, _} = application:ensure_all_started(eradius),
    spawn(fun() ->
                  eradius:modules_ready([?MODULE, eradius_proxy]),
                  timer:sleep(infinity)
          end),
    check_server_metrics().

test() ->
    application:set_env(lager, handlers, [{lager_journald_backend, []}]),
    eradius_logtest:start(),
    eradius_logtest:test_client(),
    exometer:reset([eradius, client, '127.0.0.1:1813', access_requests]),
    exometer:reset([eradius, client, '127.0.0.1:1813', accept_requests]),
    eradius_logtest:test_proxy(),
    exometer:reset([eradius, client, '127.0.0.1:11813', access_requests]),
    exometer:reset([eradius, client, '127.0.0.1:11813', accept_requests]),
    ok.

radius_request(#radius_request{cmd = request} = Request, _NasProp, _) ->
    UserName = get_attr(Request, ?User_Name),
    case lists:member(UserName, ?ALLOWD_USERS) of
        true ->
            {reply, #radius_request{cmd = accept}};
        false ->
            {reply, #radius_request{cmd = reject}}
    end;

radius_request(#radius_request{cmd = accreq}, _NasProp, _) ->
    {reply, #radius_request{cmd = accresp}}.

validate_arguments(_Args) -> true.

test_client() ->
  test_client(request).

test_client(Command) ->
    eradius_dict:load_tables([dictionary, dictionary_3gpp]),
    Request = eradius_lib:set_attributes(#radius_request{cmd = Command, msg_hmac = true}, attrs("user")),
    send_request({127, 0, 0, 1}, 1813, ?SECRET, Request),
    check_client_metrics(?CLIENT_REQUESTS_COUNT, binary_to_atom(<<"127.0.0.1:1813">>, utf8), access_requests).

test_proxy() ->
  test_proxy(request).

test_proxy(Command) ->
    eradius_dict:load_tables([dictionary, dictionary_3gpp]),
    send_request({127, 0, 0, 1}, 11813, ?SECRET2, #radius_request{cmd = Command}),
    Request = eradius_lib:set_attributes(#radius_request{cmd = Command, msg_hmac = true}, attrs("proxy_test")),
    send_request({127, 0, 0, 1}, 11813, ?SECRET2, Request),
    Request2 = eradius_lib:set_attributes(#radius_request{cmd = Command, msg_hmac = true}, attrs("user@test")),
    send_request({127, 0, 0, 1}, 11813, ?SECRET2, Request2),
    Request3 = eradius_lib:set_attributes(#radius_request{cmd = Command, msg_hmac = true}, attrs("user@domain@test")),
    send_request({127, 0, 0, 1}, 11813, ?SECRET2, Request3),
    check_client_metrics(?CLIENT_PROXY_REQUESTS_COUNT, binary_to_atom(<<"127.0.0.1:11813">>, utf8), accept_requests).

send_request(Ip, Port, Secret, Request) ->
    case eradius_client:send_request({Ip, Port, Secret}, Request) of
        {ok, Result, Auth} ->
            eradius_lib:decode_request(Result, Secret, Auth);
        Error ->
            Error
    end.

attrs(User) ->
    [{?NAS_Port, 8888},
     {?User_Name, User},
     {?NAS_IP_Address, {88,88,88,88}},
     {?Calling_Station_Id, "0123456789"},
     {?Service_Type, 2},
     {?Framed_Protocol, 7},
     {30,"some.id.com"},                  %Called-Station-Id
     {61,18},                             %NAS_PORT_TYPE
     {{10415,1}, "1337"},                 %X_3GPP-IMSI
     {{127,42},18}                        %Unbekannte ID
    ].

check_client_metrics(ValidReqCount, Addr, Metric) ->
    case exometer:get_value([eradius, client, Addr, Metric]) of
        {ok,[{value, ValidReqCount}, {ms_since_reset, _}]} ->
            ok;
        _ ->
            lager:error("Wrong value of the `access_requests` metric: ~p~n", [exometer:get_value([eradius, access_requests])])
    end.

check_server_metrics() ->
    timer:sleep(5000),
    case exometer:get_value([eradius, server, binary_to_atom(<<"127.0.0.1:11813">>, utf8), uptime]) of
       {ok, [{counter, 5}]} -> ok;
       _ -> lager:error("Wrong value of the server `uptime` metric: ~n")
    end,
    timer:sleep(15000),
    case exometer:get_value([eradius, server, binary_to_atom(<<"127.0.0.1:11813">>, utf8), uptime]) of
       {ok, [{counter, 20}]} -> ok;
       _ -> lager:error("Wrong value of the server `uptime` metric: ~n")
    end.
