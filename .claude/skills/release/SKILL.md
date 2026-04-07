---
name: release
description: Build, package, and publish a new TaskTick release to GitHub and Homebrew
user_invocable: true
---

# TaskTick Release Skill

Automate the full release workflow for TaskTick.

## Usage

```
/release <version>
```

Example: `/release 1.0.7`

## Important: Correct Order

**必须先 commit & push 代码，再执行 release 脚本。** release 脚本会创建 git tag，tag 必须指向包含所有变更的 commit。如果先创建 tag 再 push 代码，tag 会指向旧代码，用户自动更新会安装到不包含修复的版本。

## Workflow

Follow these steps **in order**:

### 1. Commit and push code changes FIRST

Back in the TaskTick repo, stage relevant changed files (do NOT use `git add -A`), commit, and push. **This must happen before the release script runs**, so the tag points to the correct commit.

```bash
git add <changed files>
git commit -m "v<version>: <description>"
git push
```

### 2. Kill running dev instance and build release

```bash
pkill -f "TaskTick Dev" 2>/dev/null
echo "y" | bash scripts/release.sh <version>
```

This builds arm64 + x86_64 DMGs, creates a GitHub tag on the latest commit, and uploads assets to GitHub Releases.

### 3. Get SHA256 of DMGs

```bash
shasum -a 256 .release/TaskTick-<version>-arm64.dmg .release/TaskTick-<version>-x86_64.dmg
```

### 4. Update release notes (bilingual)

Use `gh release edit` to set notes on GitHub. Always include both English and Chinese sections:

```
## What's Changed

### ...
(English description)

---

## 更新内容

### ...
(Chinese description)

**Full Changelog**: https://github.com/lifedever/TaskTick/compare/v<prev>...v<version>
```

Then sync the same notes to Gitee (the app reads release notes from Gitee first):

1. Get the Gitee release ID:
```bash
curl -s "https://gitee.com/api/v5/repos/lifedever/task-tick/releases/latest" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])"
```

2. Update Gitee release body using the SAME notes content. Use python3 to build the JSON payload and curl to send:
```bash
curl -s -X PATCH \
  "https://gitee.com/api/v5/repos/lifedever/task-tick/releases/<RELEASE_ID>" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json, os
body = '''<SAME_NOTES_CONTENT>'''
print(json.dumps({
    'access_token': os.environ.get('GITEE_TOKEN', ''),
    'tag_name': 'v<version>',
    'name': 'TaskTick v<version>',
    'body': body
}))
")"
```

### 5. Update Homebrew Cask

Edit `/Users/gefangshuai/Documents/Dev/myspace/homebrew-tap/Casks/task-tick.rb`:
- Update `version` to new version
- Update `sha256 arm:` and `intel:` with new SHA256 values

Then commit and push:

```bash
cd /Users/gefangshuai/Documents/Dev/myspace/homebrew-tap
git add Casks/task-tick.rb
git commit -m "Update TaskTick cask to v<version>"
git push
```

### 6. Verify tag points to correct commit

```bash
git log --oneline v<version> -1
```

Confirm the tag points to the commit that contains all the changes for this release.

### 7. Report completion

Tell the user:
- Release URL: `https://github.com/lifedever/TaskTick/releases/tag/v<version>`
- Homebrew cask updated
