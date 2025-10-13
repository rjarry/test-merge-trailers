#!/usr/bin/env bash

: ${PULL_REQUEST?PULL_REQUEST}
: ${LOGIN?LOGIN}

PR_JSON=$(gh api "$PULL_REQUEST")

pr() {
	set +x
	local attr=$1
	val=$(echo "$PR_JSON" | jq -r ".$attr")
	echo "$val"
	set -x
}

job_url() {
	set +x
	local run_id="$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
	local job_id=$(gh api "repos/$run_id/jobs" --jq ".jobs[] | select(.name==\"$GITHUB_JOB\") | .id")
	echo "https://github.com/$run_id/job/$job_id"
	set -x
}

fail() {
	set +e
	gh pr comment $(pr number) -b "error: $*

$(job_url)"
	exit 1
}

err() {
	set +e
	gh pr comment $(pr number) -b "error: command \`$BASH_COMMAND\` failed

$(job_url)"
	exit 1
}

user_name() {
	local login=$1
	local name=$(gh api users/$login --jq '.name')
	if [ -z "$name" ] || [ "$name" = null ]; then
		fail "user $LOGIN does not expose their full name"
	fi
	echo "$name"
}

email_from_gh() {
	local login=$1
	gh api users/$login --jq '.email'
}

email_from_git() {
	local name=$1
	git shortlog -se -w0 --group=author --group=committer \
		--group=trailer:acked-by --group=trailer:reviewed-by \
		--group=trailer:reported-by --group=trailer:signed-off-by \
		--group=trailer:tested-by HEAD |
	sed -En "s/^[[:space:]]+[0-9]+[[:space:]]+$name <([^@]+@[^>]+)>$/\\1/p"
}

user_email() {
	local login=$1
	local name=$2
	local email=$(email_from_gh "$login")
	if [ -z "$email" ] || [ "$email" = null ]; then
		email=$(email_from_git "$name")
		if [ -z "$email" ]; then
			fail "user $login does not expose their email and is unknown from git history"
		fi
	fi
	echo "$email"
}

set -xEe -o pipefail
trap err ERR

name=$(user_name "$LOGIN")
email=$(user_email "$LOGIN" "$name")
git config set user.name "$name"
git config set user.email "$email"

git remote add pr $(pr head.repo.clone_url)
git fetch pr
git checkout -t pr/$(pr head.ref)

tmp=$(mktemp -d)
trap "rm -rf -- $tmp" EXIT

gh api "repos/$GITHUB_REPOSITORY/pulls/$(pr number)/reviews" --paginate \
	--jq '.[] | select(.state=="APPROVED") | .user.login' | sort -u |
while read -r login; do
	name=$(user_name "$login")
	email=$(user_email "$login" "$name")
	echo "Reviewed-by: $name <$email>"
done >> "$tmp/trailers"

gh api "repos/$GITHUB_REPOSITORY/issues/$(pr number)/comments" --paginate \
	--jq '.[].body | select(test("^(Acked-by|Tested-by|Reviewed-by|Reported-by):\\s*"))' >> "$tmp/trailers"

git log --pretty=fuller $(pr base.ref)..$(pr head.ref)

git rebase $(pr base.ref) --exec \
	'git log -1 --pretty="adding trailers to %h %s" && git log -1 --pretty=%B > $tmp/msg && devtools/commit-msg $tmp/msg $tmp/trailers && git commit --amend -F $tmp/msg --no-edit'

git log --pretty=fuller $(pr base.ref)..$(pr head.ref)

git checkout $(pr base.ref)
git merge --ff-only $(pr head.ref)
git push origin $(pr base.ref)

gh pr comment $(pr number) -b "Pull request applied with git trailers: $(git log -1 --pretty=%H)

$(job_url)"

gh api -X PUT "repos/$GITHUB_REPOSITORY/pulls/$(pr number)/merge" \
	-f merge_method=rebase || gh pr close $(pr number)
