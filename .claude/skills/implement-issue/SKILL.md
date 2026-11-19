---
name: implement-issue
description: "Implement a GitHub Issue as the spec when asked to 'implement #N'; rules become tests first."
---

Read the issue with `gh issue view N --comments`; it is the spec. If it is labelled
`needs-design`, or a rule is ambiguous or contradictory, stop and ask the user
before coding. Start the branch from `develop`.

For each numbered rule, write a test first (bugs: a failing regression test that
reproduces the report), then implement. Stay inside the rules and "Out of scope";
extras become follow-ups for a new issue, not code.

Validate with code-change-validation, plus scheduling-regression or security-review
when relevant. Use the `qa`/`security` reviewers per AGENTS.md, passing the issue's
rules as acceptance criteria.

PR body: "Fixes #N", a rule -> test table and any follow-ups. Deliver per
feature-delivery, only when Git delivery is authorized.
