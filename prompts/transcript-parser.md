# Transcript Parser Skill

Parse a raw audio transcript into a structured LaTeX fragment. The
output uses \subsubsection headings per topic, \index keys below each
heading, one sentence per line, expanded contractions, corrected
grammar, and a trailing LaTeX itemized list of TODO items rendered as
unchecked boxes.

This skill supersedes the separate transcript-processing skill, which
covered the same workflow. Requests phrased as "process a transcript"
land here as well.

## Input

Accept a file path to the transcript file as the argument, or accept
the transcript text directly when pasted into the conversation. When a
file path is given, read the file using the Read tool. When text is
pasted inline, process it directly.

## Processing Steps

Apply these steps in the order given.

### 1. Remove Sound Descriptions

Remove every parenthetical that describes a non-speech sound or
ambient cue. The following list is the canonical set, and any
similar parenthetical should be removed by the same rule:

- (wind blowing)
- (gunshots)
- (foot steps)
- (train rumbling)
- (guns firing)
- (coughing)
- (sighing)
- (whistling)
- (dramatic music)
- (waves crashing)
- (air whooshing)
- (car engine rumbling)
- (clearing throat)
- (music)
- (dog barking)
- (lips smacking)
- (metal clanking)
- (wind howling)
- (thunder rumbling)
- (sighs)

Apply the same removal to any other parenthetical that describes
ambient noise, a sound effect, or a non-verbal audio cue rather than
spoken content. Do not remove parentheticals that carry semantic
content the speaker actually said.

### 2. Expand English Contractions

Replace every English contraction with its full expansion. The
following table is illustrative, not exhaustive.

- don't -> do not
- can't -> cannot
- won't -> will not
- wouldn't -> would not
- shouldn't -> should not
- couldn't -> could not
- isn't -> is not
- aren't -> are not
- wasn't -> was not
- weren't -> were not
- hasn't -> has not
- haven't -> have not
- hadn't -> had not
- I'm -> I am
- I've -> I have
- I'll -> I will
- I'd -> I would or I had (use context)
- we're -> we are
- we've -> we have
- we'll -> we will
- they're -> they are
- they've -> they have
- they'll -> they will
- you're -> you are
- you've -> you have
- you'll -> you will
- he's -> he is or he has (use context)
- she's -> she is or she has (use context)
- it's -> it is or it has (use context)
- that's -> that is or that has (use context)
- there's -> there is or there has (use context)
- who's -> who is or who has (use context)
- what's -> what is or what has (use context)
- let's -> let us
- here's -> here is

Resolve ambiguous contractions such as it's, he's, and that's by
reading the surrounding sentence.

### 3. Correct Grammar

Fix grammatical errors throughout the transcript. Enforce
subject-verb agreement, proper tense, and correct word choice. Replace
"since" with "because" whenever "since" is used to indicate causation.
Reserve "since" for temporal contexts. Repair filler-driven run-on
sentences without changing the speaker's meaning.

### 4. Parse into Paragraphs and Topic Sections

Identify distinct topics in the transcript. Group related content
into paragraphs. Create one LaTeX \subsubsection heading for each
topic. Write one sentence per line within each paragraph. Separate
paragraphs with a single blank line.

### 5. Add Index Keys

Below each \subsubsection heading insert \index entries for the
relevant key terms and phrases. Write one \index per line, in this
format:

```latex
\subsubsection{Topic Name}
\index{keyword one}
\index{keyword two}
\index{key phrase}
```

Choose index terms that a reader would look up. Favor proper nouns,
technical terms, concepts, methods, and significant phrases the
speaker discussed.

### 6. Extract TODO Items

Identify every action item, task, or thing the speaker marked as
needing to be done. Collect them into a LaTeX itemized list at the
end of the output, introduced by the `% TODO Items` comment and using
this exact format. The list must be closed with \end{itemize}.

```latex
% TODO Items
\begin{itemize}[label=\unchecked]
\item First TODO item.
\item Second TODO item.
\item Third TODO item.
\end{itemize}
```

### 7. Format the Final Output

Return the processed text as LaTeX with the following constraints.

- No preamble. Do not emit \documentclass or any \usepackage line.
- No \begin{document} or \end{document}.
- One sentence per line.
- Index keys one per line, in \index{<keyword or phrase>} form.
- The TODO list comes last.

The expected shape of the output is:

```latex
\subsubsection{First Topic}
\index{keyword}
\index{another keyword}

First sentence of first paragraph.
Second sentence of first paragraph.

First sentence of second paragraph.

\subsubsection{Second Topic}
\index{keyword}

Content sentences, one per line.

% TODO Items
\begin{itemize}[label=\unchecked]
\item Task one.
\item Task two.
\end{itemize}
```

## Output

When the input was a file path, write the processed LaTeX to a new
file in the same directory as the input file, appending
`_parsed.tex` before the extension. For example, if the input is
`meeting_notes.txt`, write `meeting_notes_parsed.tex`. Then present
the output file path to the user.

When the input was pasted inline, return the processed LaTeX in the
chat response directly, without writing a file, unless the user
explicitly asks for a file.

## Conventions

- Do not use em-dashes.
- Do not join independent phrases with a colon.
- Prefer "because" over "since" for causation.
- Expand all English contractions, including those that appear in
  paraphrases of what the speaker said.

## Verification

Before presenting the result, confirm that:

- No \documentclass, \usepackage, \begin{document}, or
  \end{document} line appears in the output.
- Every \subsubsection is followed by at least one \index line.
- No contraction remains anywhere in the body.
- No sound-description parenthetical remains.
- The TODO itemize block is the last element and is closed.
- When the input was a file, the output file exists at the expected
  `_parsed.tex` path.
