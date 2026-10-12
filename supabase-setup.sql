-- =====================================================================
-- CAMPUS IDEA TOURNAMENT  -  Supabase setup (v2, function-based)
-- ---------------------------------------------------------------------
-- HOW TO USE
--   1. Copy this file into the Supabase SQL Editor (do NOT commit your real
--      password to GitHub - this repo copy keeps the placeholder).
--   2. Change the admin password in section 5 (search for CHANGE_ME).
--   3. Run it.
--   WARNING: this DROPS the old tables (participants, ideas, reviews)
--            and all data in them.
--
-- ARCHITECTURE
--   The browser never touches tables directly. Tables have RLS ON and
--   no public policies. All reads/writes go through SECURITY DEFINER
--   functions below, which the anon key is allowed to execute.
--   -> no more "violates row-level security policy" errors,
--   -> participants cannot read or modify other people's data,
--   -> the admin dashboard needs a password.
-- =====================================================================

-- ---------- 0. Clean up old version ----------
drop function if exists get_ideas_for_review(uuid, int);
drop function if exists increment_review_count(uuid);
drop table if exists reviews      cascade;
drop table if exists ideas        cascade;
drop table if exists participants cascade;
drop table if exists app_config   cascade;

-- ---------- 1. Tables ----------
create table participants (
  id                     uuid primary key,
  session_id             uuid,
  condition              smallint not null check (condition in (1,2,3)),
                         -- 1 = look only, 2 = rank, 3 = slider 1-5
  created_at             timestamptz not null default now(),
  user_agent             text,    -- not collected (anonymity), always null
  n_ideas                int,
  n_submitted            int,
  t_generation_ms        int,
  t_screening_ms         int,
  t_selection_ms         int,
  t_evaluation_ms        int,
  screening_interactions int,     -- rank moves (cond 2) / slider changes (cond 3)
  no_ai_confirmed        boolean,
  evaluation_skipped     boolean,
  completed_at           timestamptz
);

create table ideas (
  id             uuid primary key,
  participant_id uuid not null references participants(id) on delete cascade,
  text           text not null check (char_length(text) between 1 and 1000),
  position       int,             -- order of creation
  created_at     timestamptz,
  paste_count    int not null default 0,
  pasted_chars   int not null default 0,
  screen_order   int,             -- order shown in screening (random)
  self_rank      int,             -- condition 2 only
  self_score     int check (self_score between 1 and 5),  -- condition 3 only
  submitted      boolean not null default false,
  assigned_count int not null default 0   -- times handed out for peer evaluation
);
create index ideas_participant_idx on ideas(participant_id);
create index ideas_pool_idx        on ideas(submitted, assigned_count);

create table reviews (
  id          uuid primary key default gen_random_uuid(),
  idea_id     uuid not null references ideas(id) on delete cascade,
  reviewer_id uuid not null references participants(id) on delete cascade,
  peer_rank   int  not null,      -- 1 = best
  set_size    int  not null,      -- how many ideas were in the ranked set
  -- normalised 0..1, higher = better; comparable across set sizes
  peer_score  numeric generated always as (
                case when set_size > 1
                     then (set_size - peer_rank)::numeric / (set_size - 1)
                end) stored,
  created_at  timestamptz not null default now(),
  unique (idea_id, reviewer_id)
);
create index reviews_idea_idx on reviews(idea_id);

create table app_config (key text primary key, value text not null);

-- ---------- 2. Lock tables (functions do all the work) ----------
alter table participants enable row level security;
alter table ideas        enable row level security;
alter table reviews      enable row level security;
alter table app_config   enable row level security;
revoke all on participants, ideas, reviews, app_config from anon, authenticated;

-- ---------- 3. Participant functions ----------

-- Registers participant, assigns the least-filled condition (balanced).
create or replace function register_participant(p_id uuid, p_session uuid, p_user_agent text)
returns int language plpgsql security definer set search_path = public as $$
declare v_cond int;
begin
  select condition into v_cond from participants where id = p_id;
  if found then return v_cond; end if;

  select g.cond into v_cond
  from generate_series(1,3) as g(cond)
  left join participants p on p.condition = g.cond
  group by g.cond
  order by count(p.id), random()
  limit 1;

  insert into participants(id, session_id, condition, user_agent)
  values (p_id, p_session, v_cond, left(p_user_agent, 300));
  return v_cond;
end $$;

create or replace function save_ideas(p_participant uuid, p_ideas jsonb, p_generation_ms int)
returns int language plpgsql security definer set search_path = public as $$
begin
  insert into ideas(id, participant_id, text, position, created_at, paste_count, pasted_chars)
  select (e->>'id')::uuid, p_participant, left(e->>'text', 1000),
         (e->>'position')::int, (e->>'created_at')::timestamptz,
         coalesce((e->>'paste_count')::int, 0), coalesce((e->>'pasted_chars')::int, 0)
  from jsonb_array_elements(p_ideas) e
  on conflict (id) do update set text = excluded.text;

  update participants
     set n_ideas = jsonb_array_length(p_ideas), t_generation_ms = p_generation_ms
   where id = p_participant;
  return jsonb_array_length(p_ideas);
end $$;

create or replace function save_screening(p_participant uuid, p_items jsonb, p_ms int, p_interactions int)
returns void language plpgsql security definer set search_path = public as $$
begin
  update ideas i
     set screen_order = (e->>'screen_order')::int,
         self_rank    = (e->>'self_rank')::int,
         self_score   = (e->>'self_score')::int
    from jsonb_array_elements(p_items) e
   where i.id = (e->>'id')::uuid and i.participant_id = p_participant;

  update participants
     set t_screening_ms = p_ms, screening_interactions = p_interactions
   where id = p_participant;
end $$;

-- p_ids: JSON array of idea ids the participant submits
create or replace function save_selection(p_participant uuid, p_ids jsonb, p_no_ai boolean, p_ms int)
returns void language plpgsql security definer set search_path = public as $$
begin
  update ideas
     set submitted = (id::text in (select jsonb_array_elements_text(p_ids)))
   where participant_id = p_participant;

  update participants
     set n_submitted = (select count(*) from ideas where participant_id = p_participant and submitted),
         no_ai_confirmed = p_no_ai,
         t_selection_ms = p_ms
   where id = p_participant;
end $$;

-- How many ideas are currently available for this reviewer (used while waiting).
-- p_pool: 'submitted' = only submitted ideas, 'all' = all ideas of others
create or replace function count_review_pool(p_reviewer uuid, p_pool text)
returns int language sql security definer set search_path = public as $$
  select count(*)::int
  from ideas i
  where i.participant_id <> p_reviewer
    and (p_pool = 'all' or i.submitted)
    and not exists (select 1 from reviews r where r.idea_id = i.id and r.reviewer_id = p_reviewer);
$$;

-- Hands out the n least-assigned ideas (random tie-break) and reserves them,
-- so concurrent participants spread across ideas -> balanced coverage.
create or replace function get_ideas_for_review(p_reviewer uuid, p_n int, p_pool text)
returns table(idea_id uuid, idea_text text)
language sql security definer set search_path = public as $$
  with picked as (
    select i.id
    from ideas i
    where i.participant_id <> p_reviewer
      and (p_pool = 'all' or i.submitted)
      and not exists (select 1 from reviews r where r.idea_id = i.id and r.reviewer_id = p_reviewer)
    order by i.assigned_count asc, random()
    limit p_n
    for update skip locked
  )
  update ideas i
     set assigned_count = i.assigned_count + 1
    from picked
   where i.id = picked.id
  returning i.id, i.text;
$$;

-- p_items: [{idea_id, peer_rank, set_size}, ...]
create or replace function save_reviews(p_reviewer uuid, p_items jsonb, p_ms int, p_skipped boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into reviews(idea_id, reviewer_id, peer_rank, set_size)
  select (e->>'idea_id')::uuid, p_reviewer, (e->>'peer_rank')::int, (e->>'set_size')::int
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e
  where exists (select 1 from ideas i
                where i.id = (e->>'idea_id')::uuid and i.participant_id <> p_reviewer)
  on conflict (idea_id, reviewer_id)
  do update set peer_rank = excluded.peer_rank, set_size = excluded.set_size, created_at = now();

  update participants
     set t_evaluation_ms = p_ms, evaluation_skipped = p_skipped, completed_at = now()
   where id = p_reviewer;
end $$;

-- ---------- 4. Admin functions (password protected) ----------
create or replace function admin_dump(p_pw text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_config where key = 'admin_password' and value = p_pw) then
    raise exception 'invalid admin password';
  end if;
  return jsonb_build_object(
    'participants', coalesce((select jsonb_agg(p order by p.created_at) from participants p), '[]'::jsonb),
    'ideas',        coalesce((select jsonb_agg(i order by i.created_at) from ideas i),        '[]'::jsonb),
    'reviews',      coalesce((select jsonb_agg(r order by r.created_at) from reviews r),      '[]'::jsonb)
  );
end $$;

create or replace function admin_reset(p_pw text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from app_config where key = 'admin_password' and value = p_pw) then
    raise exception 'invalid admin password';
  end if;
  truncate reviews, ideas, participants;
end $$;

-- ---------- 5. Admin password  (CHANGE THIS) ----------
insert into app_config(key, value) values ('admin_password', 'CHANGE_ME')
on conflict (key) do update set value = excluded.value;

-- ---------- 6. Allow the public (anon) key to call the functions ----------
grant execute on function register_participant(uuid, uuid, text)        to anon, authenticated;
grant execute on function save_ideas(uuid, jsonb, int)                  to anon, authenticated;
grant execute on function save_screening(uuid, jsonb, int, int)         to anon, authenticated;
grant execute on function save_selection(uuid, jsonb, boolean, int)     to anon, authenticated;
grant execute on function count_review_pool(uuid, text)                 to anon, authenticated;
grant execute on function get_ideas_for_review(uuid, int, text)         to anon, authenticated;
grant execute on function save_reviews(uuid, jsonb, int, boolean)       to anon, authenticated;
grant execute on function admin_dump(text)                              to anon, authenticated;
grant execute on function admin_reset(text)                             to anon, authenticated;

-- Refresh the API so the new functions are visible immediately
notify pgrst, 'reload schema';
