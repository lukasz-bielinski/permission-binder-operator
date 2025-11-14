# Git History Rewrite Notice

## ⚠️ IMPORTANT: Git History Has Been Rewritten (TWICE)

### **Rewrite #1** - 2025-11-13
**Reason**: Removed large binary files (`operator/main` - 73MiB) from Git history

### **Rewrite #2** - 2025-11-14 🔒 **SECURITY**
**Reason**: Removed internal documentation and session states from Git history
- **Removed**: `.internal-docs/` (14 files with internal project docs)
- **Removed**: `.session-states/` (12 files with development session history)
- **Why**: These directories contain internal development notes, not intended for public repository
- **Status**: Files preserved locally, only removed from Git history

---

## 📊 Impact

### Before Cleanup (Original)
- `.git` directory size: **~100MB+**
- Largest file in history: `operator/main` (73MiB binary)
- Internal docs in public repo: 26 files
- Slow clones for new contributors

### After Cleanup #1 (2025-11-13)
- `.git` directory size: **1.4MB** ✅
- Binary files removed
- **98% size reduction!**

### After Cleanup #2 (2025-11-14) 🔒
- `.git` directory size: **~1.0MB** ✅
- Internal docs removed from history (26 files)
- Session states removed from history
- **Clean public repository** ✅

---

## 🔧 What You Need to Do

If you have an existing clone of this repository, you need to **re-clone** or **reset** your local copy.

### Option 1: Re-clone (Recommended)

```bash
# Backup any local changes
cd /path/to/permission-binder-operator
git stash save "backup before reclone"

# Save stash reference (if needed)
git show stash@{0} > my-local-changes.patch

# Remove old clone
cd ..
rm -rf permission-binder-operator

# Fresh clone
git clone git@github.com:lukasz-bielinski/permission-binder-operator.git
cd permission-binder-operator

# Apply your local changes (if needed)
git apply my-local-changes.patch
```

### Option 2: Reset Existing Clone (Advanced)

⚠️ **WARNING**: This will lose all local commits and changes!

```bash
cd /path/to/permission-binder-operator

# Backup local changes
git stash save "backup before reset"

# Fetch new history
git fetch origin --force --tags

# Hard reset to new main
git checkout main
git reset --hard origin/main

# Force update all branches
git branch -r | grep -v '\->' | while read remote; do
    git branch --track "${remote#origin/}" "$remote" 2>/dev/null || true
done
git fetch --all
git pull --all
```

---

## 📋 What Was Removed

### Files Removed from History
- `operator/main` (73MiB) - Compiled Go binary (should never have been committed)

### Why These Files?
- **Size**: 73MiB binary taking up 98% of repository size
- **Unnecessary**: Binary files should be in `.gitignore`, not Git history
- **Performance**: Slowed down clones and increased bandwidth usage
- **Best Practice**: Binaries belong in Docker Hub, not Git

---

## ✅ Verification

After re-cloning or resetting, verify your repository is clean:

```bash
# Check .git size (should be ~1.4MB)
du -sh .git

# Check largest files in history (should be < 200KiB)
git rev-list --objects --all | \
  git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' | \
  sed -n 's/^blob //p' | \
  sort --numeric-sort --key=2 --reverse | \
  head -5 | \
  numfmt --field=2 --to=iec-i --suffix=B --padding=7

# Verify current commit
git log --oneline -3
```

Expected output:
```
1.4M    .git

dd41302 docs: update README for v1.6.0 release
80ecb0c Release v1.6.0: Security fixes & NetworkPolicy management
8fe9635 docs: add CHANGELOG entry for v1.6.0-rc3
```

---

## 🤝 For Contributors

### If You Have Open Pull Requests

Your PR will need to be rebased:

```bash
# In your fork
git fetch upstream
git checkout your-feature-branch
git rebase upstream/main
git push --force-with-lease origin your-feature-branch
```

### If You Have Local Branches

After re-cloning, recreate your local branches:

```bash
# List your branches (from old clone)
git branch -a > my-branches.txt

# In new clone, create branches
git checkout -b my-feature
git cherry-pick <commit-from-old-clone>
```

---

## 📞 Support

If you encounter issues:

1. **GitHub Issues**: [Report Here](https://github.com/lukasz-bielinski/permission-binder-operator/issues)
2. **Check**: This notice and CHANGELOG.md
3. **Verify**: You've followed the steps above

---

## 🎯 Benefits

### For New Users
- ✅ **Fast clones**: 98% smaller repository
- ✅ **Less bandwidth**: Faster downloads
- ✅ **Clean history**: No unnecessary binaries

### For Existing Users
- ✅ **Fresh start**: Clean Git history
- ✅ **Best practices**: Proper `.gitignore` usage
- ✅ **Future-proof**: No more large file issues

---

## 📚 Related Documentation

- [CHANGELOG.md](CHANGELOG.md) - Full v1.6.0 release notes
- [.gitignore](.gitignore) - Protected file patterns
- [README.md](README.md) - Main documentation

---

**Thank you for your understanding!** 🙏

This cleanup improves the repository for everyone and follows Git best practices.

