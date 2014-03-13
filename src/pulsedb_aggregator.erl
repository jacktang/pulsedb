-module(pulsedb_aggregator).
-compile(export_all).

-export([aggregate/5, migrate/4, migrate_day/3]).


migrate(TargetResolution, From, To, Path) ->
  Url = iolist_to_binary(["file://", Path]),
  {ok, Source} = pulsedb:open(undefined, [{url, Url}]),
  {ok, Target} = pulsedb:open(undefined, [{url, Url}, {resolution, TargetResolution}]),
  aggregate(TargetResolution, From, To, Source, Target).


migrate_day(TargetResolution, Date, Path) ->
  Url = iolist_to_binary(["file://", Path]),
  {ok, Source} = pulsedb:open(undefined, [{url, Url}]),
  {ok, Target} = pulsedb:open(undefined, [{url, Url}, {resolution, TargetResolution}]),
  
  UTC = pulsedb_time:parse(Date),
  DateUTC = (UTC div 86400) * 86400,
  
  Step = 3600,
  Parts = 86400 div Step,

  lager:info("migration for ~p:", [DateUTC]),
  [begin
     From = DateUTC + H*Step,
     To = DateUTC + (H+1)*Step - 1,
     try
       pulsedb_aggregator:aggregate(TargetResolution, From,To,Source, Target),
       erlang:garbage_collect(self()),
       lager:info("\t~p ok", [H]),
       ok
     catch
       C:E -> 
         lager:info("\t~p error: ~p", [H, {C,E}]),
         {error, {C,E}}
     end
   end || H <- lists:seq(0, Parts-1)].





aggregate(TargetResolution, UtcFrom, UtcTo, Source0, Target0) ->
  Interval = interval(TargetResolution),
  Aggregator = {aggregator, <<"sum">>},
  
  {ok, Data, _} = pulsedb_disk:read_all(UtcFrom, UtcTo, [Aggregator], Source0),
  Target1 = 
  lists:foldl(fun ({{Name, Tags}, Ticks}, T0) ->
                TicksAvg = make_ticks(Name, Tags, {Interval, <<"avg">>}, Ticks),
                TicksMax = make_ticks(Name, Tags, {Interval, <<"max">>}, Ticks),
                {ok, T1} = pulsedb:append(TicksAvg, T0),
                {ok, T2} = pulsedb:append(TicksMax, T1),
                T2
              end, Target0, Data),
  {ok, Target1}.


interval(minutes) -> 60;
interval(hours) -> 3600.

make_ticks(Name0, Tags, {_, Downsampler}=Ds, Ticks0) ->
  Ticks1 = pulsedb_data:downsample(Ds, Ticks0),
  Prefix = prefix(Downsampler),
  Name = <<Prefix/binary, Name0/binary>>,
  [{Name, UTC, Value, Tags} || {UTC, Value} <- Ticks1].


prefix(<<"avg">>) -> <<>>;
prefix(DS) when is_binary(DS) -> <<DS/binary, "-">>;
prefix(DS) -> iolist_to_binary(lists:concat([DS, "-"])).