-- Run in Supabase SQL Editor on a new project. Never expose the service-role key.
create extension if not exists pgcrypto;
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 username text not null, avatar_url text, is_teacher boolean not null default false,
 created_at timestamptz not null default now()
);
create table if not exists public.races (
 id uuid primary key default gen_random_uuid(), code text unique not null default upper(substr(encode(gen_random_bytes(6),'hex'),1,6)),
 title text not null, passage text not null, status text not null default 'waiting' check(status in ('waiting','running','finished')),
 duration_seconds int not null default 90 check(duration_seconds between 30 and 600),
 started_at timestamptz, finished_at timestamptz, created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);
create table if not exists public.race_participants (
 race_id uuid not null references public.races(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 joined_at timestamptz not null default now(), primary key(race_id,user_id)
);
create table if not exists public.race_results (
 race_id uuid not null references public.races(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 typed text not null, elapsed_ms int not null, wpm int not null, accuracy int not null,
 bonus_awarded boolean not null default false, submitted_at timestamptz not null default now(),
 primary key(race_id,user_id)
);
create table if not exists public.practice_results (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 lesson text not null, wpm int not null, accuracy int not null, created_at timestamptz not null default now()
);
create index if not exists race_results_user_idx on public.race_results(user_id);
create index if not exists practice_user_idx on public.practice_results(user_id,created_at desc);

create or replace function public.on_new_user() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,username,avatar_url) values(new.id,coalesce(new.raw_user_meta_data->>'user_name',new.raw_user_meta_data->>'preferred_username',split_part(new.email,'@',1),'student'),new.raw_user_meta_data->>'avatar_url') on conflict(id) do nothing;
 return new;
end $$;
drop trigger if exists auth_user_created on auth.users;
create trigger auth_user_created after insert on auth.users for each row execute function public.on_new_user();
-- Backfill accounts created before schema installation.
insert into public.profiles(id,username,avatar_url)
select id,coalesce(raw_user_meta_data->>'user_name',raw_user_meta_data->>'preferred_username',split_part(email,'@',1),'student'),raw_user_meta_data->>'avatar_url' from auth.users on conflict(id) do nothing;

alter table public.profiles enable row level security;
alter table public.races enable row level security;
alter table public.race_participants enable row level security;
alter table public.race_results enable row level security;
alter table public.practice_results enable row level security;
revoke all on public.profiles,public.races,public.race_participants,public.race_results,public.practice_results from anon;
grant select on public.profiles,public.races,public.race_participants,public.race_results,public.practice_results to authenticated;
-- All writes go through security-definer functions below. No direct client writes.
create policy profiles_read on public.profiles for select to authenticated using(true);
create policy races_read on public.races for select to authenticated using(true);
create policy participants_read on public.race_participants for select to authenticated using(true);
create policy results_read on public.race_results for select to authenticated using(true);
create policy practice_own_read on public.practice_results for select to authenticated using(user_id=auth.uid());

create or replace function public.is_teacher() returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.profiles where id=auth.uid() and is_teacher=true)$$;
create or replace function public.create_race(p_title text,p_passage text) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if not public.is_teacher() then raise exception 'Teacher permission required'; end if;
 if length(trim(p_title)) not between 3 and 100 or length(trim(p_passage)) not between 40 and 500 then raise exception 'Invalid title or passage length'; end if;
 insert into public.races(title,passage,created_by) values(trim(p_title),trim(p_passage),auth.uid()) returning id into v_id;
 return v_id;
end $$;
create or replace function public.join_race_by_id(p_race_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.races where id=p_race_id and status='waiting') then raise exception 'Race is not accepting participants'; end if;
 insert into public.race_participants(race_id,user_id) values(p_race_id,auth.uid()) on conflict do nothing;
 return p_race_id;
end $$;
create or replace function public.join_race(p_code text) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 select id into v_id from public.races where code=upper(trim(p_code)) and status='waiting';
 if v_id is null then raise exception 'Invalid code or race already started'; end if;
 return public.join_race_by_id(v_id);
end $$;
create or replace function public.start_race(p_race_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.is_teacher() then raise exception 'Teacher permission required'; end if;
 update public.races set status='running',started_at=now()+interval '5 seconds' where id=p_race_id and created_by=auth.uid() and status='waiting';
 if not found then raise exception 'Race cannot be started'; end if;
end $$;
create or replace function public.score_text(p_target text,p_typed text,p_elapsed_ms integer) returns jsonb language plpgsql immutable set search_path='' as $$
declare v_correct int:=0;v_i int;v_accuracy int;v_wpm int;
begin
 if p_elapsed_ms<=0 or length(p_typed)>length(p_target) then raise exception 'Invalid result'; end if;
 for v_i in 1..length(p_typed) loop
  if substr(p_typed,v_i,1)=substr(p_target,v_i,1) then v_correct:=v_correct+1; end if;
 end loop;
 v_accuracy:=case when length(p_typed)=0 then 0 else round(v_correct*100.0/length(p_typed))::int end;
 v_wpm:=least(300,round((v_correct/5.0)/(p_elapsed_ms/60000.0))::int);
 return jsonb_build_object('accuracy',v_accuracy,'wpm',v_wpm);
end $$;
create or replace function public.submit_race(p_race_id uuid,p_typed text,p_elapsed_ms integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_race public.races%rowtype;v_score jsonb;v_server_elapsed int;
begin
 select * into v_race from public.races where id=p_race_id for update;
 if v_race.id is null or v_race.status<>'running' then raise exception 'Race is not running'; end if;
 if not exists(select 1 from public.race_participants where race_id=p_race_id and user_id=auth.uid()) then raise exception 'Join before racing'; end if;
 if now()<v_race.started_at or now()>v_race.started_at+make_interval(secs=>v_race.duration_seconds+3) then raise exception 'Race submission outside time window'; end if;
 if exists(select 1 from public.race_results where race_id=p_race_id and user_id=auth.uid()) then raise exception 'Result already submitted'; end if;
 if p_typed<>v_race.passage then raise exception 'Finish the entire passage accurately to submit'; end if;
 v_server_elapsed:=greatest(1,(extract(epoch from (now()-v_race.started_at))*1000)::int);
 if p_elapsed_ms<1000 or p_elapsed_ms>v_race.duration_seconds*1000+3000 or p_elapsed_ms>v_server_elapsed+1500 then raise exception 'Invalid typing time'; end if;
 -- Use server time as a lower bound; browser timings cannot be trusted on their own.
 v_score:=public.score_text(v_race.passage,p_typed,greatest(p_elapsed_ms,v_server_elapsed-1500));
 if (v_score->>'wpm')::int>200 then raise exception 'Result exceeds speed limit and requires manual review'; end if;
 insert into public.race_results(race_id,user_id,typed,elapsed_ms,wpm,accuracy)
 values(p_race_id,auth.uid(),p_typed,greatest(p_elapsed_ms,v_server_elapsed-1500),(v_score->>'wpm')::int,(v_score->>'accuracy')::int);
 return v_score;
end $$;
create or replace function public.finish_race(p_race_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare v_race public.races%rowtype;v_winner uuid;
begin
 if not public.is_teacher() then raise exception 'Teacher permission required'; end if;
 select * into v_race from public.races where id=p_race_id for update;
 if v_race.id is null or v_race.created_by<>auth.uid() or v_race.status<>'running' then raise exception 'Cannot finalize this race'; end if;
 if now()<v_race.started_at+make_interval(secs=>v_race.duration_seconds) then raise exception 'Wait until the race time expires'; end if;
 select user_id into v_winner from public.race_results where race_id=p_race_id and accuracy>=90
 order by wpm desc,accuracy desc,elapsed_ms asc,submitted_at asc limit 1;
 if v_winner is not null then update public.race_results set bonus_awarded=true where race_id=p_race_id and user_id=v_winner; end if;
 update public.races set status='finished',finished_at=now() where id=p_race_id;
end $$;
create or replace function public.save_practice(p_lesson text,p_typed text,p_elapsed_ms integer) returns void language plpgsql security definer set search_path='' as $$
declare v_target text;v_score jsonb;
begin
 case p_lesson
 when 'Home row' then v_target:='asdf jkl; asdf jkl; sad lad fall flask ask dad salad';
 when 'Common words' then v_target:='the quick brown fox jumps over the lazy dog and runs away';
 when 'Everyday writing' then v_target:='Practice makes progress. Focus on accuracy before increasing your typing speed.';
 when 'Programming' then v_target:='function sum(a, b) { return a + b; } const answer = sum(2, 3);';
 else raise exception 'Unknown lesson'; end case;
 if p_typed<>v_target or p_elapsed_ms<1000 then raise exception 'Complete the lesson before saving'; end if;
 v_score:=public.score_text(v_target,p_typed,p_elapsed_ms);
 insert into public.practice_results(user_id,lesson,wpm,accuracy) values(auth.uid(),p_lesson,(v_score->>'wpm')::int,(v_score->>'accuracy')::int);
end $$;
create or replace view public.leaderboard with (security_invoker=true) as
 select p.id as user_id,p.username,count(rr.user_id) filter(where rr.bonus_awarded)::int as bonus_points,
 count(rr.user_id) filter(where rr.bonus_awarded)::int as wins
 from public.profiles p left join public.race_results rr on rr.user_id=p.id
 group by p.id,p.username order by bonus_points desc,p.username;
grant select on public.leaderboard to authenticated;
revoke execute on function public.is_teacher(),public.create_race(text,text),public.join_race_by_id(uuid),public.join_race(text),public.start_race(uuid),public.score_text(text,text,integer),public.submit_race(uuid,text,integer),public.finish_race(uuid),public.save_practice(text,text,integer) from public,anon;
grant execute on function public.is_teacher(),public.create_race(text,text),public.join_race_by_id(uuid),public.join_race(text),public.start_race(uuid),public.submit_race(uuid,text,integer),public.finish_race(uuid),public.save_practice(text,text,integer) to authenticated;
-- Enable Realtime publications for updates. Polling fallback also works.
do $$begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='races') then alter publication supabase_realtime add table public.races; end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='race_participants') then alter publication supabase_realtime add table public.race_participants; end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='race_results') then alter publication supabase_realtime add table public.race_results; end if;
end $$;
-- AFTER YOU LOG IN AS THE TEACHER, run this manually in SQL Editor:
-- update public.profiles set is_teacher=true where username='YOUR_EXACT_GITHUB_USERNAME';
