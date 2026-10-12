# Releasing

A release is a tested version with a number: a tag `vX.Y.Z` on master, the `release` branch moved
up to it, and a GitHub Release with its notes. Official clones follow `release` (a plain
`710sRice update`, and every one-line install); bleeding-edge ones follow master
(`710sRice update -Latest`; see [Official or bleeding edge](install.md#official-or-bleeding-edge)).
This page is the checklist for cutting one, and the how-to for a fork.

## The rules

- **The tag is the version.** There's no version file: doctor's first line describes a build by
  the release tags in its history -- `0.1.0` on a release, `0.1.0 + 4 commits (abc1234)` past one.
- **`release` only moves forward,** to each new release's tag. git refuses any other push to it
  without force, and nothing ever forces it. A bad release is fixed by the next one, never by
  moving `release` back: official clones never step back, and neither does the branch they follow.
- **The numbers:** `0.1.1` for fixes, `0.2.0` for features, `1.0.0` when it's declared. Always
  three: doctor and update read only `vX.Y.Z` tags.
- **The notes live on the GitHub Release** only: there's no changelog file in the repo. GitHub
  attaches the Source code zip and tar.gz itself; they aren't an install (install needs a git
  clone, because `710sRice update` runs on git).
- **No release script, no GitHub Action:** a person runs the commands below, after the checks.
- **A release is master as tested** on both machines (Windows 11 23H2 and 25H2).

## Cutting a release

From the clone you push master from, in a PowerShell 7 window. The commands use
`C:\710.DesktopRice`, the default folder; put yours if it's elsewhere. Below, `0.1.0` stands for
the last release and `0.1.1` for the new one.

1. **Check.** Nothing is changed in tracked files (this prints nothing):

   ```powershell
   git -C C:\710.DesktopRice status --short --untracked-files=no
   ```

   master is pushed (this says `Everything up-to-date`):

   ```powershell
   git -C C:\710.DesktopRice push --dry-run origin master
   ```

   What the release brings, commit by commit:

   ```powershell
   git -C C:\710.DesktopRice log --oneline v0.1.0..master
   ```

   And the pins it moves, which every official machine's update then moves too:

   ```powershell
   git -C C:\710.DesktopRice diff v0.1.0..master -- versions.md
   ```

   (The first release has no last one to compare with: those two are for every release after it.)

2. **The number and the notes.** Fixes only: the patch number goes up. Anything new: the minor
   one. The notes are for the people updating, not a commit list: what's new and what's fixed, in
   their words; the pins that move (and that the update closes and restarts those apps); anything
   the update does once, such as a re-theme when the theme's inputs changed, or anything to do by
   hand; and, for new installs, the one-liner and the manual.

3. **Tag, then push all of it at once.** The tag is annotated, on master's tip:

   ```powershell
   git -C C:\710.DesktopRice tag -a v0.1.1 -m "710.DesktopRice 0.1.1" master
   ```

   One atomic push moves master, the tag and `release` together, or none of them:

   ```powershell
   git -C C:\710.DesktopRice push --atomic origin master v0.1.1 "v0.1.1^{commit}:refs/heads/release"
   ```

   `release` gets the tag's commit (`^{commit}`); the quotes keep PowerShell from reading the
   braces. A push that would move `release` anywhere but forward is refused, and with it the rest.

4. **Publish the Release:** on GitHub, Releases > Draft a new release; choose the tag `v0.1.1`,
   title it `710.DesktopRice 0.1.1`, paste the notes, and publish. A link can open the form already
   filled in (GitHub's form takes `tag`, `title` and `body` in the address, the notes URL-encoded):
   `https://github.com/ItsAlways710/710.DesktopRice/releases/new?tag=v0.1.1&title=710.DesktopRice+0.1.1&body=...`.

5. **Check it landed.** master, `release` and the tag's commit (`v0.1.1^{}`) are the same
   commit:

   ```powershell
   git -C C:\710.DesktopRice ls-remote origin
   ```

   The Releases page lists it, and an official machine's `710sRice update` says
   `Updating 0.1.0 -> 0.1.1 (official)`, with a link to the release's page.

## The first release, once

The first release's push (step 3) creates `release` on GitHub. Before it, `710sRice update` on an
official clone says there's no release yet and leaves the clone as it is, and the one-liner has no
branch to clone; the push makes the branch and the release at the same moment.

Then, once a fresh one-line install from the release has passed: **GitHub's default branch becomes
`release`** (Settings > General > Default branch). The front page shows the default branch's
README, which is what people read before they run the one-liner -- on master it would describe work
that isn't released yet. A plain `git clone` gets the release, a fork made on GitHub copies the
branch its updates follow, and the issue forms come from the default branch (so a change to them
goes live with a release). The cost: the front page shows the last release's commit and date, and
anything started on GitHub's website (an edit, a pull request) aims at `release` unless it's
pointed at master. Until the switch, a plain `git clone` gets master: its first `710sRice update`
moves it onto the release, or keeps it where it is until the next release when master is past it.

## For a fork

A clone of your fork follows your fork: `release` (official) or master (`-Latest`), and doctor's
first line reads your tags ([Make it yours](customizing.md#forking-it-or-changing-what-it-installs)).
To give it releases, cut them the same way, against your fork's `origin`. Until your fork has a
`release` branch, `710sRice update` says there's no release and leaves the clone as it is
(`-Latest` follows your master meanwhile), and `boot.ps1` won't install. The one-liner clones this
repo, so yours needs your own `boot.ps1`, with your repo's address, and its own raw URL.
