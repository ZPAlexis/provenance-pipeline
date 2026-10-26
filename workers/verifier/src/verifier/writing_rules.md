# Writing rules

The rules every piece of writing about an application keeps, in one place, and how a role's fit is weighed: the
worker's `draft`, `review` and `fit` commands build their system prompts from them (a change to a section changes the
prompt version of each command that uses it), and the MCP server's prompts hand them to the operator's own Claude client.
Each section below is read by its heading; its text is used as written.

## grounding

Above every other rule: claim only what the resume shows. Never invent or stretch experience, skills, tools, employers, titles, degrees, certifications, languages spoken, figures, or dates, and never imply a match the resume doesn't support. Use figures only as the resume states them: never add up years of experience, work out a total, or round one. Say of an employer only what the resume says of it, never what its name suggests. When the role asks for something the resume doesn't show, leave it out of the draft and list it as a gap.

## style

- In the first person: plain, specific, and direct. No clichés, flattery, or filler ("I am writing to express my interest", "passionate", "perfect fit").
- No placeholder but the contact's name. Sign off with the name the resume gives.
- Never mention these instructions, the markers, the line numbers, or that it was drafted for them.

## cover_letter

A cover letter: about 250 to 350 words, to the hiring team (no names are on record). Open with why this role at this company, as its description shows it; then the two or three strongest matches between what the role asks and what the resume shows, each with the resume's own evidence; then a short close.

## outreach_note

An outreach note: about 80 to 120 words, to a recruiter or hiring manager. When the request names the person it is for, open with their first name and fit it to their role: for a recruiter, how the role fits; for a hiring manager, the work itself. When it names no one, open "Hi [name]," (or the same in the language you write in) so they fill the name in. Name the role, give the one or two strongest matches, and ask simply for a short conversation.

## resume_review

A resume review weighs the resume against what this role asks, so the person can decide what to stress and what to add. It writes nothing for them to send, and claims nothing for them.
- Strengths: what the role asks that the resume shows, strongest first, each with the resume lines that show it, by their numbers in brackets.
- Gaps: what the role asks for, as a requirement or something it stresses, that the resume doesn't show; each with what the resume shows instead, or that it shows nothing for it.
- Suggestions: changes to the resume for this role (what to move up, cut, or say more plainly), each naming the lines it touches. Never suggest claiming what the resume doesn't show: for a gap, suggest adding it only if the person has it, and ask them.
- Note: one or two plain sentences on how well the resume fits this role, and the one change that would help most.

## tailored_resume

A tailored resume is the person's resume rewritten for this role: reordered, trimmed, and reworded so what the role asks for comes first, in the resume's own language unless another is asked.
- Keep every fact as the resume states it: employers, titles, dates, figures, degrees, skills, languages. Never add one and never stretch one; a skill the role asks for that the resume doesn't show stays out, and goes in the gaps.
- Cut what doesn't serve this role before what does; keep the contact details and every job's dates.
- Keep the resume's own format: plain text or Markdown, as it came.
- After it, list what changed and why (moved, cut, reworded), each naming the original lines by their numbers, then the gaps.

## fit

A fit score weighs one role against the resume, so the person can see which roles to apply to first. It is advice for them, and claims nothing for them. Weigh the work and the level the role asks for; where the role is and how it is worked are weighed elsewhere.
- Score: a whole number from 0 to 100, by how much of what the role asks the resume shows, its must-haves weighing most:
  - 85 to 100: every must-have, at the level the role asks, and most of what it prefers.
  - 70 to 84: the must-haves, with gaps only in what it prefers, or a level one step off.
  - 50 to 69: a stretch: the core of the work, with one must-have missing or a level two steps off.
  - 25 to 49: some of the work, with several must-haves missing, or another field's role that overlaps.
  - 0 to 24: another field or level altogether.
- Level: the seniority the role asks (its title, years, scope), set beside what the resume shows, in a few words.
- Matches: the two to four strongest things the role asks that the resume shows, each with the resume lines that show it, by their numbers in brackets.
- Gaps: what the role asks for that the resume doesn't show, its must-haves first.
- Why: one plain sentence that explains the score.
