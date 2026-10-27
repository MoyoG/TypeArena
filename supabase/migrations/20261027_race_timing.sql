-- Apply this migration to an existing TypeArena Supabase project.
alter table public.races alter column duration_seconds set default 60;

revoke execute on function public.join_race_by_id(uuid) from authenticated;

create or replace function public.submit_race(p_race_id uuid,p_typed text,p_elapsed_ms integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_race public.races%rowtype;v_score jsonb;v_server_elapsed integer;v_effective integer;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into v_race from public.races where id=p_race_id for update;
 if v_race.id is null or v_race.status<>'running' then raise exception 'Race is not running'; end if;
 if not exists(select 1 from public.race_participants where race_id=p_race_id and user_id=auth.uid()) then
  raise exception 'Join before racing';
 end if;
 if now()<v_race.started_at or now()>v_race.started_at+make_interval(secs=>v_race.duration_seconds+10) then
  raise exception 'Race submission outside time window';
 end if;
 if exists(select 1 from public.race_results where race_id=p_race_id and user_id=auth.uid()) then
  raise exception 'Result already submitted';
 end if;
 if p_typed is null or length(p_typed)>length(v_race.passage) then raise exception 'Invalid typed passage'; end if;
 v_server_elapsed:=greatest(1,(extract(epoch from(now()-v_race.started_at))*1000)::integer);
 if p_elapsed_ms is null or p_elapsed_ms<1000 or p_elapsed_ms>v_race.duration_seconds*1000+10000
 or p_elapsed_ms>v_server_elapsed+1500 then raise exception 'Invalid typing time'; end if;
 v_effective:=greatest(p_elapsed_ms,v_server_elapsed-1500);
 v_score:=public.score_text(v_race.passage,p_typed,v_effective);
 if (v_score->>'wpm')::integer>200 then raise exception 'Result requires teacher review'; end if;
 insert into public.race_results(race_id,user_id,elapsed_ms,wpm,accuracy)
 values(p_race_id,auth.uid(),v_effective,(v_score->>'wpm')::integer,(v_score->>'accuracy')::integer);
 return v_score;
end $$;

grant execute on function public.submit_race(uuid,text,integer) to authenticated;
