-- =====================================================================
-- Student Scholarship Monitoring and Academic Compliance System
-- Run this whole file once in Supabase -> SQL Editor -> New query
-- =====================================================================

-- ---------- 1. TABLES -------------------------------------------------
create table if not exists profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null,
  role       text not null default 'scholar' check (role in ('admin','staff','scholar'))
);

create table if not exists scholarship_programs (
  id                  uuid primary key default gen_random_uuid(),
  program_name        text not null unique,
  -- Philippine scale (1.00 best ... 5.00 fail): scholar passes if GWA <= required_gwa
  required_gwa        numeric(3,2) not null check (required_gwa between 1.00 and 5.00),
  min_units           int  not null check (min_units >= 0),
  allow_failing_grade boolean not null default false,
  active              boolean not null default true
);

create table if not exists scholars (
  id             uuid primary key default gen_random_uuid(),
  student_id     text not null unique check (length(trim(student_id)) > 0),
  full_name      text not null check (length(trim(full_name)) > 0),
  degree_program text not null,
  year_level     int  not null check (year_level between 1 and 6),
  scholarship_id uuid not null references scholarship_programs(id),
  status         text not null default 'Active' check (status in
                   ('Active','Pending Submission','For Verification','Compliant',
                    'With Deficiency','Probationary','For Renewal','Renewed','Disqualified')),
  user_id        uuid references auth.users(id),   -- optional: links a scholar login
  created_at     timestamptz not null default now()
);

create table if not exists grade_submissions (
  id                  uuid primary key default gen_random_uuid(),
  scholar_id          uuid not null references scholars(id),
  academic_year       text not null check (academic_year ~ '^[0-9]{4}-[0-9]{4}$'),
  semester            text not null check (semester in ('1st Semester','2nd Semester','Summer')),
  gwa                 numeric(3,2) not null check (gwa between 1.00 and 5.00),
  units_enrolled      int not null check (units_enrolled >= 0),
  failed_subjects     int not null default 0 check (failed_subjects >= 0),
  incomplete_subjects int not null default 0 check (incomplete_subjects >= 0),
  submission_status   text not null default 'Pending'
                        check (submission_status in ('Pending','Verified','Returned')),
  submitted_at        timestamptz not null default now(),
  verified_by         uuid references auth.users(id),
  verified_at         timestamptz,
  evaluation_result   text check (evaluation_result in ('Compliant','With Deficiency')),
  deficiency_notes    text
);

-- BR-03: one active submission per scholar + academic year + semester
create unique index if not exists uq_submission_period
  on grade_submissions (scholar_id, academic_year, semester)
  where submission_status <> 'Returned';

-- BR-08: audit trail for changes to academic records
create table if not exists audit_log (
  id         bigint generated always as identity primary key,
  table_name text, record_id uuid, action text,
  old_data   jsonb, new_data jsonb,
  changed_by uuid default auth.uid(),
  changed_at timestamptz default now()
);

-- ---------- 2. HELPERS ------------------------------------------------
create or replace function is_staff() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from profiles where id = auth.uid() and role in ('admin','staff'));
$$;

-- auto-create a profile (default role = scholar) when a user signs up
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email));
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- a new submission moves the scholar to "For Verification"
create or replace function on_submission_created() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update scholars set status = 'For Verification' where id = new.scholar_id;
  return new;
end $$;
drop trigger if exists trg_submission_created on grade_submissions;
create trigger trg_submission_created after insert on grade_submissions
  for each row execute function on_submission_created();

-- audit trigger (BR-08)
create or replace function audit_changes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log(table_name, record_id, action, old_data, new_data)
  values (tg_table_name, coalesce(new.id, old.id), tg_op,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;
drop trigger if exists trg_audit_submissions on grade_submissions;
create trigger trg_audit_submissions after insert or update or delete on grade_submissions
  for each row execute function audit_changes();

-- ---------- 3. VERIFICATION + COMPLIANCE RULE ---------------------------
-- BR-04 only staff/admin; BR-09 cannot verify twice; BR-05 evaluate only after verified
-- BR-02/BR-07 the rule comes from the scholar's own scholarship program.
create or replace function verify_submission(p_submission_id uuid)
returns grade_submissions
language plpgsql security definer set search_path = public as $$
declare
  s grade_submissions; p scholarship_programs; notes text[] := '{}'; result text;
begin
  if not is_staff() then raise exception 'Only authorized staff may verify submissions.'; end if;

  select * into s from grade_submissions where id = p_submission_id for update;
  if not found then raise exception 'Submission not found.'; end if;
  if s.submission_status <> 'Pending' then
    raise exception 'Submission is already % and cannot be verified again.', s.submission_status;
  end if;

  select sp.* into p from scholarship_programs sp
    join scholars sc on sc.scholarship_id = sp.id where sc.id = s.scholar_id;

  -- Philippine grading scale: LOWER GWA is BETTER, so GWA must be <= required_gwa
  if s.gwa > p.required_gwa then
    notes := notes || format('GWA %s is worse than the required %s', s.gwa, p.required_gwa);
  end if;
  if s.units_enrolled < p.min_units then
    notes := notes || format('Units enrolled %s is below the minimum %s', s.units_enrolled, p.min_units);
  end if;
  if s.failed_subjects > 0 and not p.allow_failing_grade then
    notes := notes || format('%s failed subject(s) but this scholarship allows none', s.failed_subjects);
  end if;
  if s.incomplete_subjects > 0 then  -- BR-06 mandatory requirement incomplete
    notes := notes || format('%s incomplete subject(s) must be completed', s.incomplete_subjects);
  end if;

  result := case when array_length(notes,1) is null then 'Compliant' else 'With Deficiency' end;

  update grade_submissions
     set submission_status = 'Verified', verified_by = auth.uid(), verified_at = now(),
         evaluation_result = result, deficiency_notes = array_to_string(notes, '; ')
   where id = p_submission_id returning * into s;

  update scholars set status = result where id = s.scholar_id;
  return s;
end $$;

create or replace function return_submission(p_submission_id uuid, p_reason text default null)
returns grade_submissions
language plpgsql security definer set search_path = public as $$
declare s grade_submissions;
begin
  if not is_staff() then raise exception 'Only authorized staff may return submissions.'; end if;
  update grade_submissions
     set submission_status = 'Returned', deficiency_notes = p_reason
   where id = p_submission_id and submission_status = 'Pending' returning * into s;
  if not found then raise exception 'Only pending submissions can be returned.'; end if;
  update scholars set status = 'Pending Submission' where id = s.scholar_id;
  return s;
end $$;

-- ---------- 4. ROW LEVEL SECURITY (BR-10) --------------------------------
alter table profiles              enable row level security;
alter table scholarship_programs  enable row level security;
alter table scholars              enable row level security;
alter table grade_submissions     enable row level security;
alter table audit_log             enable row level security;

drop policy if exists p_profiles_read   on profiles;
create policy p_profiles_read on profiles for select using (id = auth.uid() or is_staff());

drop policy if exists p_prog_read  on scholarship_programs;
drop policy if exists p_prog_write on scholarship_programs;
create policy p_prog_read  on scholarship_programs for select using (auth.uid() is not null);
create policy p_prog_write on scholarship_programs for all using (is_staff()) with check (is_staff());

drop policy if exists p_sch_read  on scholars;
drop policy if exists p_sch_write on scholars;
create policy p_sch_read  on scholars for select using (is_staff() or user_id = auth.uid());
create policy p_sch_write on scholars for all using (is_staff()) with check (is_staff());

drop policy if exists p_sub_read   on grade_submissions;
drop policy if exists p_sub_insert on grade_submissions;
create policy p_sub_read on grade_submissions for select using (
  is_staff() or scholar_id in (select id from scholars where user_id = auth.uid()));
create policy p_sub_insert on grade_submissions for insert with check (
  submission_status = 'Pending' and (
    is_staff() or scholar_id in (select id from scholars where user_id = auth.uid())));
-- NOTE: no UPDATE policy on grade_submissions: verification only via verify_submission()

drop policy if exists p_audit_read on audit_log;
create policy p_audit_read on audit_log for select using (is_staff());

grant execute on function verify_submission(uuid)       to authenticated;
grant execute on function return_submission(uuid,text)  to authenticated;

-- ---------- 5. SAMPLE SCHOLARSHIP RULES ----------------------------------
insert into scholarship_programs (program_name, required_gwa, min_units, allow_failing_grade) values
  ('University Academic Scholarship (Full)',   1.75, 18, false),
  ('CHED Merit Scholarship',                   2.00, 15, false),
  ('Private Sponsor Grant',                    2.50, 12, true),
  ('Government Financial Assistance (TES)',    3.00, 12, true)
on conflict (program_name) do nothing;

-- ---------- 6. MAKE YOURSELF STAFF (run AFTER creating a user) -----------
-- Authentication -> Users -> Add user (tick "Auto confirm"), then:
-- update profiles set role = 'admin' where id = (select id from auth.users where email = 'you@example.com');
