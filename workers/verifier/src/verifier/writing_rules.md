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

## background_resume

When the person's background not on the resume is given, it is their own word about experience, skills and context the resume compresses or leaves out, each line numbered B1, B2 and so on. It extends what may be said of them only as follows, and only for a resume review or a tailored resume.
- A resume review may name a strength the background shows for what the role asks, or suggest adding a line from it to the resume. A tailored resume may bring a line from it in, in the resume's own style.
- Each point, suggestion or change drawn from it names its background lines, so it is flagged "from your background, not on the resume" for the person to confirm before they use it.
- Never present it as already on the resume, never claim more than its lines state, and never draw on it for anything else: a gap it doesn't cover stays a gap.

## background_letter

When what the person is looking for is given, it is their own word on their motivation: the kind of role and work they want, and where they want to grow. A cover letter or an outreach note may use it for why they want this role, in their voice, and only for that.
- It is never a claim of experience: every claim of what they have done still traces to a line of the resume, and none of its lines is ever cited as a line drawn on.
- Use it only where the role connects to it. Never recite it, and never let it promise what the resume doesn't show.

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

## background_fit

A role's fit is read two ways. The ATS fit is the resume alone, as a recruiter's screening system would read it: weigh it by the fit rules, from the resume and the role's description only, and never let the background raise it. The Background fit reads the person's background too, given beside the resume in three parts (what they're looking for, their role preferences, their background not on the resume), each line numbered B1, B2 and so on: their own word, to weigh as true, never a resume line.
- Background score: a whole number from 0 to 100, on the fit rules' bands, from the resume and the background together. The role preferences weigh in here alone: a role they could do but don't want (the wrong kind of work, seniority or arrangement) scores lower here than its skills would put it.
- Covered gaps: each gap of the ATS reading that the background covers, with what the role asks, the background lines that cover it, and where to address it (the resume, the cover letter, or both), and a short note on how. A gap the background doesn't cover stays a gap, and isn't listed here.
- Preferences: how the role sits with each role preference it touches, a match or a miss, with why and its background lines. Leave out a preference the role says nothing about: unknown is never a match.
- Why: one plain sentence that explains the Background score beside the ATS one.

## company_fit

A company review weighs one company against the person's company preferences (what they want and what they avoid, in their own words, and the stages, sizes, business models, industries and words to avoid they listed), and where it hires against the places they can work, so they can see which companies to watch first. It is advice for them, and claims nothing for them. Weigh only what you can source: a page you read, never a guess.
- Facts: what it sells and to whom, its stage and last funding, its size, where it is based, the regions it operates and hires in, its technology, signals (growth, layoffs, news), and values or positions it has stated, each with the links behind it. Give its stage, size, business model and industries in the person's own terms where they apply.
- Points: one per preference, each a match (it meets it), a miss (it doesn't) or unknown (nothing found), with the evidence and its links. Unknown is never a match: say what you could not find.
- Score: a whole number from 0 to 100, by how much of what the person wants it meets, what they want most weighing most:
  - 85 to 100: it meets what they want most, nothing they avoid, and hires where they can work.
  - 70 to 84: most of what they want, nothing they avoid, with a gap or two in what matters less.
  - 50 to 69: some of what they want, nothing they avoid, or too much unknown to say more.
  - 25 to 49: little of what they want, or something they avoid.
  - 0 to 24: little or nothing they want, and what they avoid.
- Something they avoid that it does is a miss on that preference, and caps the score at 49, however much else it meets.
- A review that knows less than it doesn't (more unknown than met and missed together) says so in its why.
- Concerns and open questions: what would change the score, and what to ask or look for next.
- Why: one plain sentence that explains the score.
