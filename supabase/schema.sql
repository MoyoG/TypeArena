-- TypeArena schema v2. Intended for a NEW, EMPTY Supabase project.
-- Execute once in SQL Editor as project owner. Do not paste secrets into client code.
create extension if not exists pgcrypto;

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 username text not null, avatar_url text,
 is_teacher boolean not null default false,
 created_at timestamptz not null default now()
);
create table public.races (
 id uuid primary key default gen_random_uuid(),
 code text unique not null default upper(substr(encode(gen_random_bytes(8),'hex'),1,8)),
 title text not null, passage text not null,
 status text not null default 'waiting' check (status in ('waiting','running','finished')),
 duration_seconds integer not null default 90 check(duration_seconds between 30 and 600),
 started_at timestamptz, finished_at timestamptz,
 created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);
create table public.race_participants (
 race_id uuid not null references public.races(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 joined_at timestamptz not null default now(),
 primary key(race_id,user_id)
);
create table public.race_results (
 race_id uuid not null references public.races(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 elapsed_ms integer not null check(elapsed_ms > 0),
 wpm integer not null check(wpm between 0 and 300),
 accuracy integer not null check(accuracy between 0 and 100),
 bonus_awarded boolean not null default false,
 submitted_at timestamptz not null default now(),
 primary key(race_id,user_id)
);
create unique index one_bonus_per_race on public.race_results(race_id) where bonus_awarded;
create index race_results_user_idx on public.race_results(user_id);
create table public.typing_lessons (
 title text primary key, level integer not null check(level between 1 and 4),
 passage text not null check(length(passage) between 20 and 3000)
);
create table public.practice_results (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id) on delete cascade,
 lesson text not null,
 wpm integer not null check(wpm between 0 and 300),
 accuracy integer not null check(accuracy between 0 and 100),
 verified boolean not null default false,
 created_at timestamptz not null default now()
);
create index practice_user_idx on public.practice_results(user_id,created_at desc);


-- Seed the 20 lessons, matching the React frontend exactly.
insert into public.typing_lessons(title,level,passage) values
 ('Home and family',1,'home family mother father sister brother garden morning evening together happy kind warm'),
 ('Nature',1,'forest river mountain ocean flower tree cloud sunshine wind rain valley field'),
 ('School',1,'student teacher classroom lesson book pencil paper reading writing learning question answer'),
 ('Daily routine',1,'wake breakfast walk work lunch dinner relax sleep fresh early quiet comfortable'),
 ('Travel',1,'journey station ticket hotel airport bicycle train village city explore discover adventure'),
 ('Daily numbers',2,'There are 12 students in room 5 and 24 books on shelf 3'),
 ('Shopping',2,'Buy 4 apples 6 oranges and 2 loaves for a family of 5'),
 ('Schedules',2,'The train leaves at 8 and arrives at 10 after 2 stops'),
 ('Science facts',2,'Water freezes at 0 degrees and boils at 100 degrees at sea level'),
 ('Classroom results',2,'Student 14 solved 18 questions in 25 minutes and earned 90 points'),
 ('A short note',3,'Hello, Alex! Please bring 3 notebooks, 2 pens, and your ID.'),
 ('A reminder',3,'At 9:30, call the office; then, email 2 reports before 5:00.'),
 ('Weather report',3,'Today, the temperature is 28 degrees; tomorrow, it may reach 31.'),
 ('The question',3,'Why did 7 students arrive late? The bus, unfortunately, stopped twice.'),
 ('Instructions',3,'Step 1: Open the file. Step 2: Read it carefully. Step 3: Save your work!'),
 ('Email addresses',4,'Contact help@example.com or admin@school.edu; include ticket #204.'),
 ('Prices and discounts',4,'A $45.00 item with 20% off costs $36.00; add a 5% fee.'),
 ('Keyboard symbols',4,'Use @, #, $, %, &, *, +, =, /, \, and _ when required.'),
 ('Code and brackets',4,'Set value = (12 + 8) * 3; check [value] != {0} && value >= 20.'),
 ('Mixed challenge',4,'User_27 paid $19.99 @ 8:45; status = "OK"! Ref: #A-302 & B/7.');

-- GitHub OAuth profile provisioning. Only database owner should alter teacher roles.
create function public.on_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 insert into public.profiles(id,username,avatar_url)
 values(new.id,
 coalesce(nullif(new.raw_user_meta_data->>'user_name',''),nullif(new.raw_user_meta_data->>'preferred_username',''),nullif(split_part(coalesce(new.email,''),'@',1),''),'student'),
 new.raw_user_meta_data->>'avatar_url') on conflict(id) do nothing;
 return new;
end $$;
create trigger auth_user_created after insert on auth.users
for each row execute function public.on_new_user();

alter table public.profiles enable row level security;
alter table public.races enable row level security;
alter table public.race_participants enable row level security;
alter table public.race_results enable row level security;
alter table public.typing_lessons enable row level security;
alter table public.practice_results enable row level security;

revoke all on public.profiles, public.races, public.race_participants,
 public.race_results, public.typing_lessons, public.practice_results from anon, authenticated;
grant select on public.profiles,public.races,public.race_participants,
 public.race_results,public.typing_lessons,public.practice_results to authenticated;
create policy profiles_read on public.profiles for select to authenticated using(true);
create policy races_read on public.races for select to authenticated using(true);
create policy participants_read on public.race_participants for select to authenticated using(true);
create policy results_read on public.race_results for select to authenticated using(true);
create policy lessons_read on public.typing_lessons for select to authenticated using(true);
create policy practice_own_read on public.practice_results for select to authenticated
 using(user_id=(select auth.uid()));

create function public.is_teacher() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles where id=(select auth.uid()) and is_teacher=true)
$$;
create function public.create_race(p_title text,p_passage text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if auth.uid() is null or not public.is_teacher() then raise exception 'Teacher permission required'; end if;
 if length(trim(coalesce(p_title,''))) not between 3 and 100 or
 length(trim(coalesce(p_passage,''))) not between 40 and 500 then raise exception 'Invalid title or passage length'; end if;
 insert into public.races(title,passage,created_by)
 values(trim(p_title),trim(p_passage),auth.uid()) returning id into v_id;
 return v_id;
end $$;
create function public.join_race_by_id(p_race_id uuid) returns uuid
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not exists(select 1 from public.races where id=p_race_id and status='waiting') then
 raise exception 'Race is not accepting participants'; end if;
 insert into public.race_participants(race_id,user_id) values(p_race_id,auth.uid()) on conflict do nothing;
 return p_race_id;
end $$;
create function public.join_race(p_code text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select id into v_id from public.races where code=upper(trim(p_code)) and status='waiting';
 if v_id is null then raise exception 'Invalid code or race already started'; end if;
 return public.join_race_by_id(v_id);
end $$;
create function public.start_race(p_race_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not public.is_teacher() then raise exception 'Teacher permission required'; end if;
 update public.races set status='running',started_at=now()+interval '5 seconds'
 where id=p_race_id and created_by=auth.uid() and status='waiting';
 if not found then raise exception 'Race cannot be started'; end if;
end $$;
create function public.score_text(p_target text,p_typed text,p_elapsed_ms integer) returns jsonb
language plpgsql immutable set search_path='' as $$
declare v_correct integer:=0;v_i integer;v_accuracy integer;v_wpm integer;
begin
 if p_target is null or p_typed is null or p_elapsed_ms is null or p_elapsed_ms<=0
 or length(p_typed)>length(p_target) then raise exception 'Invalid result'; end if;
 for v_i in 1..length(p_typed) loop
  if substr(p_typed,v_i,1)=substr(p_target,v_i,1) then v_correct:=v_correct+1; end if;
 end loop;
 v_accuracy:=case when length(p_typed)=0 then 0 else round(v_correct*100.0/length(p_typed))::integer end;
 v_wpm:=least(300,round((v_correct/5.0)/(p_elapsed_ms/60000.0))::integer);
 return jsonb_build_object('accuracy',v_accuracy,'wpm',v_wpm);
end $$;
create function public.submit_race(p_race_id uuid,p_typed text,p_elapsed_ms integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_race public.races%rowtype;v_score jsonb;v_server_elapsed integer;v_effective integer;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into v_race from public.races where id=p_race_id for update;
 if v_race.id is null or v_race.status<>'running' then raise exception 'Race is not running'; end if;
 if not exists(select 1 from public.race_participants where race_id=p_race_id and user_id=auth.uid()) then
 raise exception 'Join before racing'; end if;
 if now()<v_race.started_at or now()>v_race.started_at+make_interval(secs=>v_race.duration_seconds+3)
 then raise exception 'Race submission outside time window'; end if;
 if exists(select 1 from public.race_results where race_id=p_race_id and user_id=auth.uid())
 then raise exception 'Result already submitted'; end if;
 if p_typed is distinct from v_race.passage then raise exception 'Finish the passage accurately'; end if;
 v_server_elapsed:=greatest(1,(extract(epoch from(now()-v_race.started_at))*1000)::integer);
 if p_elapsed_ms is null or p_elapsed_ms<1000 or p_elapsed_ms>v_race.duration_seconds*1000+3000
 or p_elapsed_ms>v_server_elapsed+1500 then raise exception 'Invalid typing time'; end if;
 v_effective:=greatest(p_elapsed_ms,v_server_elapsed-1500);
 v_score:=public.score_text(v_race.passage,p_typed,v_effective);
 if (v_score->>'wpm')::integer>200 then raise exception 'Result requires teacher review'; end if;
 insert into public.race_results(race_id,user_id,elapsed_ms,wpm,accuracy)
 values(p_race_id,auth.uid(),v_effective,(v_score->>'wpm')::integer,(v_score->>'accuracy')::integer);
 return v_score;
end $$;
create function public.finish_race(p_race_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v_race public.races%rowtype;v_winner uuid;
begin
 if auth.uid() is null or not public.is_teacher() then raise exception 'Teacher permission required'; end if;
 select * into v_race from public.races where id=p_race_id for update;
 if v_race.id is null or v_race.created_by<>auth.uid() or v_race.status<>'running'
 then raise exception 'Cannot finalize this race'; end if;
 if now()<v_race.started_at+make_interval(secs=>v_race.duration_seconds)
 then raise exception 'Wait until race time expires'; end if;
 select user_id into v_winner from public.race_results
 where race_id=p_race_id and accuracy>=90
 order by wpm desc,accuracy desc,elapsed_ms asc,submitted_at asc limit 1;
 if v_winner is not null then
 update public.race_results set bonus_awarded=true where race_id=p_race_id and user_id=v_winner;
 end if;
 update public.races set status='finished',finished_at=now() where id=p_race_id;
end $$;

-- Supports 20 fixed lessons. For timed tests, accept a prefix of the 18x repeated
-- official passage. Practice scores are NOT course bonus points.
-- Custom passages cannot be independently verified: store as unverified.
create function public.save_practice(p_lesson text,p_typed text,p_elapsed_ms integer) returns void
language plpgsql security definer set search_path='' as $$
declare v_base text;v_target text;v_score jsonb;v_verified boolean:=true;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_elapsed_ms is null or p_elapsed_ms<1000 or p_elapsed_ms>3600000 or
 p_typed is null or length(p_typed)=0 or length(p_typed)>50000 then
 raise exception 'Invalid practice submission'; end if;
 select passage into v_base from public.typing_lessons where title=p_lesson;
 if v_base is null then
  if p_lesson<>'Custom text' then raise exception 'Unknown lesson'; end if;
  -- Cannot validate custom text against a trusted server-side target.
  v_verified:=false;v_target:=p_typed;
 else
  v_target:=repeat(v_base||' ',17)||v_base;
  if length(p_typed)>length(v_target) then raise exception 'Typed text exceeds lesson'; end if;
 end if;
 v_score:=public.score_text(v_target,p_typed,p_elapsed_ms);
 insert into public.practice_results(user_id,lesson,wpm,accuracy,verified)
 values(auth.uid(),p_lesson,(v_score->>'wpm')::integer,(v_score->>'accuracy')::integer,v_verified);
end $$;

create view public.leaderboard with (security_invoker=true) as
 select p.id as user_id,p.username,
 count(rr.user_id) filter(where rr.bonus_awarded)::integer as bonus_points,
 count(rr.user_id) filter(where rr.bonus_awarded)::integer as wins
 from public.profiles p left join public.race_results rr on rr.user_id=p.id
 group by p.id,p.username;
grant select on public.leaderboard to authenticated;

-- Functions are executable by PUBLIC by default; explicitly restrict RPCs.
revoke execute on function public.on_new_user(),public.is_teacher(),public.create_race(text,text),
 public.join_race_by_id(uuid),public.join_race(text),public.start_race(uuid),
 public.score_text(text,text,integer),public.submit_race(uuid,text,integer),
 public.finish_race(uuid),public.save_practice(text,text,integer) from public,anon;
grant execute on function public.is_teacher(),public.create_race(text,text),
 public.join_race_by_id(uuid),public.join_race(text),public.start_race(uuid),
 public.submit_race(uuid,text,integer),public.finish_race(uuid),
 public.save_practice(text,text,integer) to authenticated;

-- Realtime subscriptions. Existing client also polls every 4 seconds.
do $$begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='races') then
  alter publication supabase_realtime add table public.races; end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='race_participants') then
  alter publication supabase_realtime add table public.race_participants; end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='race_results') then
  alter publication supabase_realtime add table public.race_results; end if;
end $$;

-- TEACHER ACTIVATION (RUN SEPARATELY AFTER FIRST GITHUB SIGN-IN):
-- update public.profiles set is_teacher=true where id='YOUR_AUTH_USER_UUID'::uuid;
