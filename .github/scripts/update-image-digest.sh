#!/usr/bin/env bash
set -euo pipefail
# Promotes a container image digest from one branch (source) to
# another branch (target) by:
# - cloning a repo,
# - locating the single image@sha256:... reference for the specified image
#   name on the source and target branches,
# - creating (or reusing) a feature branch from the target,
# - replacing the target branch's image digest with the source branch digest
#   in all YAML files,
# - committing and pushing the change,
# - creating or updating a PR.
#
# Example Usage:
# ./update-image-digest.sh -o my-org -r my-repo -s main -t stable -f update-stable-util-image -i quay.io/my-org/my-image -d false
#
# Image Details
NEW_DIGEST=""
OLD_DIGEST=""
TMP_DIR="$(mktemp -d)"
REPO_DIR="$TMP_DIR/repo"

show_help() {
	cat <<EOF
Automated Image Digest Promotion
Usage: $0 -o ORG -r REPO -s SOURCE_BRANCH -t TARGET_BRANCH -i IMAGE -d DRY_RUN
  -o | --org       GitHub org/user
  -r | --repo      repository name
  -s | --source    source branch
  -t | --target    target branch
  -f | --feature   feature branch name (e.g. update-stable-util-image)
  -i | --image     image name (e.g. quay.io/org/image)
  -d | --dry-run   'true' or 'false'
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-o | --org)
			ORG="$2"
			shift 2
			;;
		-r | --repo)
			REPO="$2"
			shift 2
			;;
		-s | --source)
			SOURCE_BRANCH="$2"
			shift 2
			;;
		-t | --target)
			TARGET_BRANCH="$2"
			shift 2
			;;
		-f | --feature)
			FEATURE_BRANCH="$2"
			shift 2
			;;
		-i | --image)
			IMG="$2"
			shift 2
			;;
		-d | --dry-run)
			DRY_RUN="$2"
			shift 2
			;;
		-h | --help)
			show_help
			exit 0
			;;
		*)
			echo "Error: Unknown option: $1"
			exit 1
			;;
		esac
	done
}

validate_config() {
	valid=true
	if [[ -z "${GITHUB_TOKEN:-}" ]]; then
		echo "Error: GITHUB_TOKEN environment variable is not set"
		valid=false
	fi

	if [[ -z "${GIT_AUTHOR_NAME:-}" ]]; then
		echo "Error: GIT_AUTHOR_NAME environment variable is not set"
		valid=false
	fi

	if [[ -z "${GIT_AUTHOR_EMAIL:-}" ]]; then
		echo "Error: GIT_AUTHOR_EMAIL environment variable is not set"
		valid=false
	fi

	if [[ -z "${ORG:-}" ]]; then
		echo "Error: ORG cannot be empty"
		valid=false
	fi

	if [[ -z "${REPO:-}" ]]; then
		echo "Error: REPO cannot be empty"
		valid=false
	fi

	if [[ -z "${SOURCE_BRANCH:-}" ]]; then
		echo "Error: SOURCE_BRANCH cannot be empty"
		valid=false
	fi

	if [[ -z "${TARGET_BRANCH:-}" ]]; then
		echo "Error: TARGET_BRANCH cannot be empty"
		valid=false
	fi

	if [[ -z "${FEATURE_BRANCH:-}" ]]; then
		echo "Error: FEATURE_BRANCH cannot be empty"
		valid=false
	fi

	if [[ -z "${IMG:-}" ]]; then
		echo "Error: IMAGE_NAME cannot be empty"
		valid=false
	fi

	if [[ "${DRY_RUN:-}" != "true" && "${DRY_RUN:-}" != "false" ]]; then
		echo "Error: DRY_RUN must be 'true' or 'false', got: ${DRY_RUN:-}"
		valid=false
	fi

	if [[ ! $valid == true ]]; then
		exit 1
	fi
}

clone_repo() {
	echo "Cloning https://github.com/$ORG/$REPO ..."
	git clone "https://oauth2:${GITHUB_TOKEN}@github.com/$ORG/$REPO.git" "$REPO_DIR"
}

find_image_digest_refs() {
	branch="$1"
	refs=()
	git checkout "$branch"
	echo "Searching branch: $branch for ${IMG}@sha256:..."
	while IFS= read -r match; do
		refs+=("$match")
	done < <(git grep -I -h -E -o "${IMG}@sha256:[a-f0-9]{64}" -- '*.yml' '*.yaml' 2>/dev/null)

	refs=($(printf '%s\n' "${refs[@]}" | sort -u))

	if [[ ${#refs[@]} -eq 0 ]]; then
		echo "Error: no references to ${IMG} found on '${branch}'"
		return 1
	fi

	if [[ ${#refs[@]} -ne 1 ]]; then
		echo "Error: multiple distinct references found on '${branch}':"
		printf '  %s\n' "${refs[@]}"
		return 1
	fi

	if [[ "$branch" == "${SOURCE_BRANCH:-}" ]]; then
		NEW_DIGEST="${refs[0]}"
	else
		OLD_DIGEST="${refs[0]}"
	fi

	echo "Found: ${refs[0]} on branch $branch"
}

checkout_branch() {
	git fetch origin
	git checkout -B "$TARGET_BRANCH" "origin/$TARGET_BRANCH"

	if git ls-remote --exit-code --heads origin "$FEATURE_BRANCH"; then
		echo "Feature branch exists; checking it out"
		git checkout -B "$FEATURE_BRANCH" "origin/$FEATURE_BRANCH"
	else
		echo "Creating feature branch"
		git checkout -B "$FEATURE_BRANCH" "origin/$TARGET_BRANCH"
	fi

	# Reset to the latest target to have no changes
	git reset --hard "origin/$TARGET_BRANCH"
}

# Replace the image sha in all YAML files that reference it.
replace_image_references() {
	git checkout "$FEATURE_BRANCH"
	sed -i'' -e "s|${IMG}@sha256:[a-f0-9]\{64\}|${NEW_DIGEST}|g" $(find . -type f \( -name "*.yml" -o -name "*.yaml" \))
	echo "Updated image references in branch: $FEATURE_BRANCH"
}

create_commit_and_push() {
	git config user.name "$GIT_AUTHOR_NAME"
	git config user.email "$GIT_AUTHOR_EMAIL"
	git add $(find . -type f \( -name "*.yml" -o -name "*.yaml" \))
	git commit -m "chore(deps): bump ${IMG} from ${OLD_DIGEST: -7} to ${NEW_DIGEST: -7}" \
		-m "$(
			cat <<EOF
Promote ${IMG} digest on ${TARGET_BRANCH}.

- source (${SOURCE_BRANCH}): ${NEW_DIGEST}
- target (${TARGET_BRANCH}): ${OLD_DIGEST}

Signed-off-by: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>
EOF
		)"

	if [[ "$DRY_RUN" == "true" ]]; then
		echo "DRY RUN: skip creating PR"
		return 0
	fi
	git push --force-with-lease -u origin "$FEATURE_BRANCH"
}

open_pr() {
	pr_number=""
	title="chore(deps): bump ${IMG} from \`${OLD_DIGEST: -7}\` to \`${NEW_DIGEST: -7}\`"
	changed_files=$(git diff --name-only "$TARGET_BRANCH" "$FEATURE_BRANCH")
	num_files=$(echo "$changed_files" | grep -c .)
	files_list=$(echo "$changed_files" | awk '{print "  - " $0}')

	body="$(
		cat <<EOF
Promote \`${IMG}\` digest on \`${TARGET_BRANCH}\`.

- source (\`${SOURCE_BRANCH}\`): \`${NEW_DIGEST}\`
- target (\`${TARGET_BRANCH}\`): \`${OLD_DIGEST}\`
- files changed (${num_files}):
${files_list}
EOF
	)"

	if [[ "$DRY_RUN" == "true" ]]; then
		echo "DRY RUN: skip creating PR"
		return 0
	fi

	pr_number="$(gh api "repos/${ORG}/${REPO}/pulls" \
		-X GET -f state=open -f head="${ORG}:${FEATURE_BRANCH}" -f base="${TARGET_BRANCH}" \
		--jq '.[0].number' 2>/dev/null || true)"

	if [[ -n "$pr_number" ]]; then
		echo "Updating existing PR #${pr_number}"
		gh api -X PATCH "repos/${ORG}/${REPO}/pulls/${pr_number}" \
			-f "title=${title}" \
			-f "body=${body}" >/dev/null
		return 0
	fi

	echo "Creating a new PR"
	gh api -X POST "repos/${ORG}/${REPO}/pulls" \
		-f "title=${title}" \
		-f "body=${body}" \
		-f "base=${TARGET_BRANCH}" \
		-f "head=${FEATURE_BRANCH}" >/dev/null
}

trap 'rm -rf "$TMP_DIR"' EXIT
parse_args "$@"
validate_config
clone_repo
cd "$REPO_DIR"
find_image_digest_refs "$SOURCE_BRANCH"
find_image_digest_refs "$TARGET_BRANCH"
if [[ "$OLD_DIGEST" == "$NEW_DIGEST" ]]; then
	echo "No update needed: target already matches source."
	exit 0
fi
checkout_branch
replace_image_references
create_commit_and_push
open_pr

echo "Updating of image digests complete...."
echo "All changes have been pushed to the feature branch: $FEATURE_BRANCH"
echo "PR: https://github.com/${ORG}/${REPO}/pull/${pr_number}"
