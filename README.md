# Scholarship Monitoring System: Part II setup, tests and submission pack

## What is in this folder
| File | Purpose |
|---|---|
| `Part1_Requirements_Analysis.md` | Part I: problems, actors, interview questions, FR/NFR/BR, statuses, use cases, traceability, ERD |
| `use_case_diagram.svg` | UML use case diagram (6 actors, 19 use cases, 4 include, 3 extend) |
| `schema.sql` | Tables, constraints, RLS, verification and compliance function, sample scholarship rules |
| `index.html` | The whole front end (HTML, CSS, JavaScript in one file) |

## 1. Set up Supabase (about 10 minutes)
1. Create a project at supabase.com.
2. **SQL Editor → New query**, paste all of `schema.sql`, run it.
3. **Authentication → Users → Add user**, tick *Auto confirm*, create your staff account.
4. Make it staff by running in the SQL Editor:
   `update profiles set role = 'admin' where id = (select id from auth.users where email = 'you@example.com');`
5. Optional scholar login: create another user (role stays `scholar`), then link it:
   `update scholars set user_id = (select id from auth.users where email = 'scholar@example.com') where student_id = '2024-0001';`
6. **Project Settings → API**: copy the Project URL and the `anon` public key into the top of the `<script>` in `index.html` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`). Never use the `service_role` key in the front end.

## 2. Deploy on GitHub Pages
```bash
git init
git add . && git commit -m "Initialize scholarship monitoring system"
# create an empty repo on GitHub, then:
git remote add origin https://github.com/<you>/<repo>.git
git branch -M main && git push -u origin main
```
Repo **Settings → Pages → Deploy from branch → main / (root)**. The site appears at `https://<you>.github.io/<repo>/`.

Suggested commits (at least four): `Initialize scholarship monitoring system` (analysis files), `Create scholar and scholarship database modules` (schema.sql, scholar and program pages), `Implement grade submission and verification`, `Add compliance evaluation dashboard and deployment`.

## 3. Rule choices documented
- **Grading scale:** Philippine, 1.00 (best) to 5.00 (fail). Lower is better, so a scholar meets the GWA rule when `GWA <= required_gwa`. Change the range in `GWA_MIN` / `GWA_MAX` and in `schema.sql` if your institution differs.
- **Compliance rule:** Compliant only if GWA passes AND units ≥ minimum AND (failed subjects = 0 OR program allows failing) AND incomplete subjects = 0. The incomplete-subject check goes one step beyond the lab's minimum logic to honor BR-06; delete that `if` block in `verify_submission()` to follow the minimum logic exactly.
- **Where the rule runs:** in the database function `verify_submission()`, so it cannot be bypassed from the browser (BR-04, BR-05, BR-09). Staff have no UPDATE permission on `grade_submissions`.

## 4. Sample data for the demonstration
Register these scholars, then add a submission for each and verify:

| Student ID | Program | GWA | Units | Failed | Incomplete | Expected |
|---|---|---|---|---|---|---|
| 2024-0001 | CHED Merit Scholarship (2.00, 15 units, no failing) | 1.75 | 18 | 0 | 0 | Compliant |
| 2024-0002 | CHED Merit Scholarship | 2.35 | 18 | 0 | 0 | With Deficiency (GWA) |
| 2024-0003 | Private Sponsor Grant (2.50, 12 units, failing allowed) | 2.25 | 12 | 1 | 0 | Compliant (shows per-program policy) |
| 2024-0004 | University Academic Scholarship (1.75, 18 units) | 1.50 | 15 | 0 | 0 | With Deficiency (units) |

## 5. Functional test results (fill in after you run them)
| Test ID | Scenario | Expected result | Actual / Pass? |
|---|---|---|---|
| TC-01 | Login with valid authorized account | Dashboard opens | |
| TC-02 | Create scholar with complete data | Scholar saved | |
| TC-03 | Create scholar without Student ID | Rejected: "Student ID cannot be blank." | |
| TC-04 | Submit semester grades | Saved as Pending; scholar becomes For Verification | |
| TC-05 | Verify pending submission | Status becomes Verified | |
| TC-06 | Evaluate scholar meeting requirements (2024-0001) | Compliant | |
| TC-07 | Evaluate scholar failing a requirement (2024-0002) | With Deficiency, with reason | |
| TC-08 | Search by Student ID or name | Matching scholar shown | |
| TC-09 | Filter by scholarship / status | Correct subset shown | |
| TC-10 | Open deployed URL | System accessible online | |
| Extra | Verify the same submission twice (call rpc again) | Refused (BR-09) | |
| Extra | Log in as scholar, try to see other scholars | Only own data visible (BR-10) | |

## 6. Requirements-to-implementation table
| Requirement | Use Case | Implemented Feature | Test | Result |
|---|---|---|---|---|
| FR-01 | Register Scholar | Scholar form (`scholarForm`) | TC-02, TC-03 | |
| FR-02 | Assign Scholarship | Program dropdown, `scholarship_id NOT NULL` | TC-02 | |
| FR-03 | Configure Scholarship Requirements | Scholarship Programs page | TC-06, TC-07 | |
| FR-04 | Submit Grades | Grade submission form | TC-04 | |
| FR-06 | Verify Grade Submission | Verify button → `verify_submission()` | TC-05 | |
| FR-07 | Evaluate Academic Compliance | Compliance logic inside `verify_submission()` | TC-06, TC-07 | |
| FR-10 | View Dashboard | Pending counter | TC-04 | |
| FR-14 | Search Scholar | Search box | TC-08 | |
| FR-15 | Filter Scholars | Program and status filters | TC-09 | |

## 7. Submission checklist
- [ ] GitHub repository URL
- [ ] Live deployed URL
- [ ] `use_case_diagram.svg` (open in a browser and screenshot, or export to PNG)
- [ ] Final functional requirements (section D of the Part I file)
- [ ] ERD (Mermaid block in the Part I file renders on GitHub; or screenshot Supabase's Schema Visualizer)
- [ ] At least four Git commits
- [ ] Filled test results (section 5)
- [ ] Requirements-to-implementation table (section 6)
- [ ] 2 to 4 screenshots: Pending submission, Verified result, Dashboard, Compliance page
