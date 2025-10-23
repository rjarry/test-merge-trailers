#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025 Robin Jarry

set -xe

: ${GH_TOKEN:?}
: ${PR_NUMBER:?}
: ${PR_COMMITS:?}
: ${HEAD_REF:?}
: ${TRAILER:?}

gh auth setup-git

# configure git identity to the most recent committer
GIT_COMMITTER_NAME=$(git log -1 --pretty=%cN)
GIT_COMMITTER_EMAIL=$(git log -1 --pretty=%cE)
git config set user.name "$GIT_COMMITTER_NAME"
git config set user.email "$GIT_COMMITTER_EMAIL"
export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# add commit-msg hook to remove duplicate trailers and ensure correct ordering
rm -f .git/hooks/commit-msg
ln -s ../../devtools/commit-msg .git/hooks/commit-msg

# rewrite all commit messages, appending the trailer
GIT_TRAILER_DEBUG=1 git rebase "HEAD~$PR_COMMITS" \
	--exec "git commit -C HEAD --no-edit --amend --trailer='$TRAILER'"

git push --force origin "$HEAD_REF"
