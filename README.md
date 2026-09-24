# sieve

Find and grep in one vocabulary.

Every other tool splits the question in two. `find` asks about file names, `grep` asks about
file contents, and you have to decide which one you meant before you start. Nobody remembers
it that way. You remember that something had a word in it somewhere.

So sieve looks in both places, and tells you how it found each hit.

    sieve hacker

Names and contents, in the current directory. That is the whole command.

## What it looks like

    $ sieve sieve
    sieve-notes.txt name+content
         1: the sieve writes code
         3: another sieve line

    sub/c.md content
         1: sieve

    sieve: 1 by name, 2 files with content matches, 3 lines in . (5 files looked at, read by
    rg across all cores, 2 machine dirs skipped, in 0.02 s)

Every hit says why it matched: `name`, `content`, or `name+content`. The summary says what was
searched, what was skipped, which engine read it, and how long it took.

## Install

One file, no dependencies.

    install -m 755 sieve ~/.local/bin/sieve

It uses `rg` and `fd` when they are installed and works without them. With `rg` it reads
contents across all cores. With `fd` it lists files in parallel. With neither it walks and
reads in-process, same output, slower, and the summary says which one happened.

## Options

    --in DIR              where to look, default .
    --named GLOB          only files whose name matches GLOB
    --today               only files modified today
    --since 3d            only files modified within a window
    --bigger 100k         only files larger than this
    --no-bigger 10M       skip files larger than this
    --regex               treat the pattern as a regex, default is a plain literal
    -i                    case-insensitive
    --files               names only, no file is opened
    --text                contents only
    -c                    one count per file instead of the lines
    -m N                  at most N lines per file
    --no-ignore           walk .git, node_modules and the machine's own caches too
    --color auto|always|never
    --explain             print the find and grep this stood in for

Exit codes are the grep family. 0 matched, 1 nothing matched, 2 the command was wrong.

## The rules it holds itself to

A pattern is a literal unless you ask for a regex, so `foo(bar)` searches for `foo(bar)`.

A skip is never silent. The default ignore list skips the machine's own bookkeeping, package
caches, browser profiles, compiled runtimes. The summary always says what was skipped, and
`--no-ignore` walks everything.

A match inside a very long line gets a window around it, with an ellipsis on whichever side
was cut, so the word is visible instead of buried in ninety thousand characters of transcript.

A filename containing a newline or a tab is escaped on display, so one file is always exactly
one line of output and nothing reading it sees a file that does not exist.

It always says something. A run that matched nothing still prints what it looked at and how
long it took.

Odd files do not kill it. A line that is not valid UTF-8 is read lossily and the search
continues.

## Why it is fast

Not because of the Python. Because it hands the work to tools that are already fast. `fd`
lists, `rg` reads across all cores. The Python part is the vocabulary, the join between names
and contents, the printer and the summary.

Measured on a home directory, 296,085 files after the ignore list, searching for one word:

    bare form, names and contents     1.36 s
    names only                        0.40 s
    contents only                     0.76 s

The first working version took ninety seconds on the same tree.

## Tests

    ./tests/smoke.sh

Builds a scratch tree with known answers and checks the behaviour above, including the exit
codes, the ignore list, and the pipe safety.

Both lanes are exercised on odd trees as well, the fast one and the slow one: FIFOs, symlink
loops, broken symlinks, unreadable files and directories, latin-1 lines, files with no trailing
newline, empty files, binaries, a 96 KB single line, a file over the size cap, and filenames
containing spaces, tabs, colons, quotes, backslashes, emoji, a leading dash and a newline. The
two lanes have to return the same answer on every one of them.

## License

MIT.
