#!/bin/bash

# Copyright 2019 The gVisor Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -xeou pipefail

# GitHub Actions exports committer email with an empty name. Git honors those
# environment variables over local config, which breaks merge/commit below.
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
export GIT_AUTHOR_NAME='gVisor bot'
export GIT_AUTHOR_EMAIL='gvisor-bot@google.com'
export GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"

# Remember our current directory.
declare orig_dir
orig_dir=$(pwd)
readonly orig_dir

# Record the current working commit.
declare head
head=$(git describe --always)
readonly head

# Create a temporary working directory, and ensure that this directory and all
# subdirectories are cleaned up upon exit.
declare tmp_dir
tmp_dir=$(mktemp -d)
readonly tmp_dir
finish() {
  cd "${orig_dir}"          # Leave tmp_dir.
  rm -rf "${tmp_dir}"       # Remove all contents.
  git checkout -f "${head}" # Restore commit.
}
trap finish EXIT

# Discover the package name from the go.mod file.
declare module origpwd othersrc
module=$(cat go.mod | grep -E "^module" | cut -d' ' -f2)
origpwd=$(pwd)
othersrc=("go.mod" "go.sum" "AUTHORS" "LICENSE")
readonly module origpwd othersrc

# Build a full gopath.
declare -r go_output="${tmp_dir}/output"
make build BAZEL_OPTIONS="" TARGETS="//:gopath"
unzip bazel-bin/gopath.zip -d "${go_output}"

# We expect to have an existing go branch that we will use as the basis for this
# commit. That branch may be empty, but it must exist. We search for this branch
# using the local branch, the "origin" branch, and other remotes, in order.
# Forks that have never run this workflow may have no go branch yet; bootstrap
# one with an empty tree commit so the merge below can proceed.
git fetch --all
declare go_branch
if git show-ref --verify --quiet refs/heads/go; then
  go_branch=$(git rev-parse refs/heads/go)
elif git show-ref --verify --quiet refs/remotes/origin/go; then
  go_branch=$(git rev-parse refs/remotes/origin/go)
else
  echo "Bootstrapping missing go branch with empty root commit." >&2
  readonly empty_tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904
  go_branch=$(git commit-tree -m "Initial synthetic go branch" "${empty_tree}")
  git branch go "${go_branch}"
fi
readonly go_branch

# Clone the current repository to the temporary directory, and check out the
# current go_branch directory. We move to the new repository for convenience.
declare repo_orig
repo_orig="$(pwd)"
readonly repo_orig
declare -r repo_new="${tmp_dir}/repository"
git clone . "${repo_new}"
cd "${repo_new}"

# Setup the repository and checkout the branch.
git config user.email "${GIT_AUTHOR_EMAIL}"
git config user.name "${GIT_AUTHOR_NAME}"
if git show-ref --verify --quiet refs/remotes/origin/go; then
  git fetch origin go
  git checkout -B go origin/go
else
  git checkout -B go "${go_branch}"
fi

# Start working on a merge commit that combines the previous history with the
# current history. Note that we don't actually want any changes yet.
#
# N.B. The git behavior changed at some point and the relevant flag was added
# to allow for override, so try the only behavior first then pass the flag.
git merge --no-commit --strategy ours "${head}" || \
  git merge --allow-unrelated-histories --no-commit --strategy ours "${head}"

# Normalize the permissions on the old branch. Note that they should be
# normalized if constructed by this tool, but we do so before the rsync.
find . -type f -exec chmod 0644 {} \;
find . -type d -exec chmod 0755 {} \;

# Sync the entire gopath. Note that we exclude auto-generated source files that
# will change here. Otherwise, it adds a tremendous amount of noise to commits.
# If this file disappears in the future, then presumably we will still delete
# the underlying directory.
declare -r gopath="${go_output}/src/${module}"
rsync --recursive --delete \
  --exclude .git \
  "${gopath}/" .

# Add additional files.
for file in "${othersrc[@]}"; do
  cp "${origpwd}"/"${file}" .
done

# Construct a new README.md.
cat > README.md <<EOF
# gVisor

This branch is a synthetic branch, containing only Go sources, that is
compatible with standard Go tools. See the master branch for authoritative
sources and tests.
EOF

# There are a few solitary files that can get left behind due to the way bazel
# constructs the gopath target. Note that we don't find all Go files here
# because they may correspond to unused templates, etc.
declare -ar binaries=( "runsc" "shim" "webhook" "tools/checklocks/cmd/checklocks" )
for target in "${binaries[@]}"; do
  mkdir -p "${target}"
  cp "${repo_orig}/${target}"/*.go "${target}/"
done

# Normalize all permissions. The way bazel constructs the :gopath tree may leave
# some strange permissions on files. We don't have anything in this tree that
# should be execution, only the Go source files, README.md, and ${othersrc}.
find . -type f -exec chmod 0644 {} \;
find . -type d -exec chmod 0755 {} \;

# Update the current working set and commit.
# If the current working commit has already been committed to the remote go
# branch, then we have nothing to commit here. So allow empty commit. This can
# occur when this script is run parallelly (via pull_request and push events)
# and the push workflow finishes before the pull_request workflow can run this.
git add --all && git commit --allow-empty -m "Merge ${head} (automated)"

# Push the branch back to the original repository.
git remote add orig "${repo_orig}" && git push -f orig go:go
