# Migracja z Git CLI na go-git Library

> **Status**: Przykłady do przyszłej implementacji  
> **Data**: 2025-01-15  
> **Cel**: Migracja z `exec.CommandContext("git", ...)` na bibliotekę `github.com/fluxcd/go-git/v5`  
> **Powód**: Lepsza kompatybilność z Bitbucket Server on-premise (wsparcie dla `multi_ack`)

## Dlaczego fork FluxCD?

### Bitbucket Server on-premise wymaga:
- ✅ Wsparcie dla `multi_ack` i `multi_ack_detailed` protokołów
- ✅ Lepsza kompatybilność z on-premise serwerami Git
- ✅ FluxCD używa tego forka w produkcji z Bitbucket Server

### Różnice:
- `github.com/go-git/go-git/v5` - oryginalna biblioteka (brak `multi_ack`)
- `github.com/fluxcd/go-git/v5` - fork FluxCD (z `multi_ack`)

## Plan migracji

### 1. Aktualizacja `go.mod`

```go
// Zamiast:
github.com/go-git/go-git/v5 v5.16.3

// Użyj:
github.com/fluxcd/go-git/v5 v5.16.3
```

### 2. Aktualizacja importów

```go
// Zamiast:
import "github.com/go-git/go-git/v5"

// Użyj:
import "github.com/fluxcd/go-git/v5"
```

## Przykłady implementacji

### Clone Repository

**Obecna implementacja (CLI):**
```go
// operator/internal/controller/networkpolicy/git_cli.go
func cloneGitRepo(ctx context.Context, repoURL string, credentials *gitCredentials) (string, error) {
    cmd := exec.CommandContext(ctx, "git", "clone", "--depth", "1", authURL, tmpDir)
    // ...
}
```

**Nowa implementacja (biblioteka):**
```go
func cloneGitRepoUsingLibrary(ctx context.Context, repoURL string, credentials *gitCredentials) (string, error) {
    logger := log.FromContext(ctx)

    tmpDir, err := os.MkdirTemp("", "permission-binder-git-*")
    if err != nil {
        return "", fmt.Errorf("failed to create temp directory: %w", err)
    }

    // Parse URL and prepare auth
    u, err := url.Parse(repoURL)
    if err != nil {
        os.RemoveAll(tmpDir)
        return "", fmt.Errorf("failed to parse repo URL: %w", err)
    }

    // Prepare authentication
    auth := &http.BasicAuth{
        Username: credentials.username,
        Password: credentials.token,
    }

    logger.V(1).Info("Cloning Git repository using go-git library", "url", repoURL, "tempDir", tmpDir)

    // Clone with shallow depth (equivalent to --depth 1)
    _, err = git.PlainCloneContext(ctx, tmpDir, false, &git.CloneOptions{
        URL:           repoURL,
        Auth:          auth,
        Depth:         1,
        SingleBranch:  true,
        Progress:      os.Stdout, // Optional: can be nil for silent operation
        Tags:          git.NoTags,
    })

    if err != nil {
        os.RemoveAll(tmpDir)
        networkPolicyGitOperationsTotal.WithLabelValues("clone", "error").Inc()
        return "", fmt.Errorf("failed to clone repository: %w", err)
    }

    networkPolicyGitOperationsTotal.WithLabelValues("clone", "success").Inc()
    return tmpDir, nil
}
```

### Checkout Branch

**Obecna implementacja (CLI):**
```go
func gitCheckoutBranch(ctx context.Context, repoDir string, branchName string, create bool) error {
    cmd := exec.CommandContext(ctx, "git", "checkout", "-b", branchName)
    // ...
}
```

**Nowa implementacja (biblioteka):**
```go
func checkoutBranchUsingLibrary(ctx context.Context, repoDir string, branchName string, create bool) error {
    // Open repository
    repo, err := git.PlainOpen(repoDir)
    if err != nil {
        return fmt.Errorf("failed to open repository: %w", err)
    }

    // Get worktree
    worktree, err := repo.Worktree()
    if err != nil {
        return fmt.Errorf("failed to get worktree: %w", err)
    }

    // Check if branch exists
    branchRef := plumbing.NewBranchReferenceName(branchName)
    _, err = repo.Reference(branchRef, false)
    branchExists := err == nil

    if !branchExists && !create {
        return fmt.Errorf("branch %s does not exist", branchName)
    }

    if !branchExists && create {
        // Create new branch from HEAD
        headRef, err := repo.Head()
        if err != nil {
            return fmt.Errorf("failed to get HEAD: %w", err)
        }

        // Create branch reference
        newRef := plumbing.NewHashReference(branchRef, headRef.Hash())
        if err := repo.Storer.SetReference(newRef); err != nil {
            return fmt.Errorf("failed to create branch: %w", err)
        }
    }

    // Checkout branch
    err = worktree.Checkout(&git.CheckoutOptions{
        Branch: branchRef,
        Create: create,
        Force:  false,
    })

    if err != nil {
        return fmt.Errorf("failed to checkout branch: %w", err)
    }

    return nil
}
```

### Commit and Push

**Obecna implementacja (CLI):**
```go
func gitCommitAndPush(ctx context.Context, repoDir string, branchName string, commitMessage string, credentials *gitCredentials) error {
    cmd := exec.CommandContext(ctx, "git", "add", "-A")
    cmd := exec.CommandContext(ctx, "git", "commit", "-m", commitMessage)
    cmd := exec.CommandContext(ctx, "git", "push", "origin", branchName)
    // ...
}
```

**Nowa implementacja (biblioteka):**
```go
func commitAndPushUsingLibrary(ctx context.Context, repoDir string, branchName string, commitMessage string, credentials *gitCredentials) error {
    logger := log.FromContext(ctx)

    // Open repository
    repo, err := git.PlainOpen(repoDir)
    if err != nil {
        return fmt.Errorf("failed to open repository: %w", err)
    }

    // Get worktree
    worktree, err := repo.Worktree()
    if err != nil {
        return fmt.Errorf("failed to get worktree: %w", err)
    }

    // Check status
    status, err := worktree.Status()
    if err != nil {
        return fmt.Errorf("failed to get status: %w", err)
    }

    // Check if there are changes
    if status.IsClean() {
        logger.V(1).Info("No changes to commit")
        return nil
    }

    // Add all changes (equivalent to git add -A)
    err = worktree.AddWithOptions(&git.AddOptions{All: true})
    if err != nil {
        return fmt.Errorf("failed to add changes: %w", err)
    }

    // Commit
    commitHash, err := worktree.Commit(commitMessage, &git.CommitOptions{
        Author: &object.Signature{
            Name:  credentials.username,
            Email: credentials.email,
            When:  time.Now(),
        },
    })
    if err != nil {
        return fmt.Errorf("failed to commit: %w", err)
    }

    logger.V(1).Info("Committed changes", "hash", commitHash.String())

    // Get remote
    remote, err := repo.Remote("origin")
    if err != nil {
        return fmt.Errorf("failed to get remote: %w", err)
    }

    // Prepare authentication
    auth := &http.BasicAuth{
        Username: credentials.username,
        Password: credentials.token,
    }

    // Fetch to check if branch exists on remote
    branchRef := plumbing.NewBranchReferenceName(branchName)
    err = remote.FetchContext(ctx, &git.FetchOptions{
        Auth:  auth,
        RefSpecs: []config.RefSpec{config.RefSpec(fmt.Sprintf("+refs/heads/%s:refs/remotes/origin/%s", branchName, branchName))},
    })

    remoteBranchExists := err == nil || err == git.NoErrAlreadyUpToDate

    if remoteBranchExists {
        // Branch exists on remote - force push for operator-managed branches
        logger.V(1).Info("Branch exists on remote, force pushing", "branch", branchName)
        err = remote.PushContext(ctx, &git.PushOptions{
            Auth: auth,
            RefSpecs: []config.RefSpec{
                config.RefSpec(fmt.Sprintf("+refs/heads/%s:refs/heads/%s", branchName, branchName)),
            },
            Force: true, // Force push for operator-managed branches
        })
    } else {
        // Branch doesn't exist on remote - normal push with upstream
        logger.V(1).Info("Branch doesn't exist on remote, pushing new branch", "branch", branchName)
        err = remote.PushContext(ctx, &git.PushOptions{
            Auth: auth,
            RefSpecs: []config.RefSpec{
                config.RefSpec(fmt.Sprintf("refs/heads/%s:refs/heads/%s", branchName, branchName)),
            },
        })
    }

    if err != nil {
        if err == git.NoErrAlreadyUpToDate {
            logger.V(1).Info("Remote is already up to date")
            networkPolicyGitOperationsTotal.WithLabelValues("push", "success").Inc()
            return nil
        }
        networkPolicyGitOperationsTotal.WithLabelValues("push", "error").Inc()
        return fmt.Errorf("failed to push: %w", err)
    }

    networkPolicyGitOperationsTotal.WithLabelValues("push", "success").Inc()
    logger.Info("Pushed changes to remote", "branch", branchName)
    return nil
}
```

### Fetch Latest Changes

**Obecna implementacja (CLI):**
```go
// operator/internal/controller/networkpolicy/reconciliation_single.go
cmd := exec.CommandContext(ctx, "git", "fetch", "origin", baseBranch)
```

**Nowa implementacja (biblioteka):**
```go
func fetchLatestChangesUsingLibrary(ctx context.Context, repoDir string, branchName string, credentials *gitCredentials) error {
    repo, err := git.PlainOpen(repoDir)
    if err != nil {
        return fmt.Errorf("failed to open repository: %w", err)
    }

    remote, err := repo.Remote("origin")
    if err != nil {
        return fmt.Errorf("failed to get remote: %w", err)
    }

    auth := &http.BasicAuth{
        Username: credentials.username,
        Password: credentials.token,
    }

    err = remote.FetchContext(ctx, &git.FetchOptions{
        Auth: auth,
        RefSpecs: []config.RefSpec{
            config.RefSpec(fmt.Sprintf("+refs/heads/%s:refs/remotes/origin/%s", branchName, branchName)),
        },
    })

    if err != nil && err != git.NoErrAlreadyUpToDate {
        return fmt.Errorf("failed to fetch: %w", err)
    }

    return nil
}
```

### Reset to Remote Branch

**Obecna implementacja (CLI):**
```go
// operator/internal/controller/networkpolicy/reconciliation_single.go
cmd = exec.CommandContext(ctx, "git", "reset", "--hard", fmt.Sprintf("origin/%s", baseBranch))
```

**Nowa implementacja (biblioteka):**
```go
func resetToRemoteBranchUsingLibrary(ctx context.Context, repoDir string, branchName string) error {
    repo, err := git.PlainOpen(repoDir)
    if err != nil {
        return fmt.Errorf("failed to open repository: %w", err)
    }

    worktree, err := repo.Worktree()
    if err != nil {
        return fmt.Errorf("failed to get worktree: %w", err)
    }

    // Get remote branch reference
    remoteRef := plumbing.NewRemoteReferenceName("origin", branchName)
    remoteRefObj, err := repo.Reference(remoteRef, true)
    if err != nil {
        return fmt.Errorf("failed to get remote reference: %w", err)
    }

    // Reset to remote branch
    err = worktree.Reset(&git.ResetOptions{
        Mode:   git.HardReset,
        Commit: remoteRefObj.Hash(),
    })

    if err != nil {
        return fmt.Errorf("failed to reset: %w", err)
    }

    return nil
}
```

## Wymagane importy

```go
import (
    "context"
    "fmt"
    "net/url"
    "os"
    "time"

    "github.com/fluxcd/go-git/v5"
    "github.com/fluxcd/go-git/v5/config"
    "github.com/fluxcd/go-git/v5/plumbing"
    "github.com/fluxcd/go-git/v5/plumbing/object"
    "github.com/fluxcd/go-git/v5/plumbing/transport/http"
    "sigs.k8s.io/controller-runtime/pkg/log"
)
```

## Pliki do modyfikacji

1. **`operator/go.mod`** - zmiana z `go-git/go-git` na `fluxcd/go-git`
2. **`operator/internal/controller/networkpolicy/git_cli.go`** - zastąpienie funkcji CLI biblioteką
3. **`operator/internal/controller/networkpolicy/reconciliation_single.go`** - użycie nowych funkcji
4. **`operator/internal/controller/networkpolicy/reconciliation_cleanup.go`** - użycie nowych funkcji

## Zalety migracji

### ✅ Korzyści:
- **Pure Go** - brak zależności od zewnętrznego binarnego `git`
- **Lepsza kontrola** - pełna kontrola nad operacjami Git
- **Kompatybilność** - wsparcie dla `multi_ack` (Bitbucket Server)
- **Bezpieczeństwo** - mniejsza powierzchnia ataku (brak exec)
- **Testowanie** - łatwiejsze mockowanie i testy jednostkowe
- **Wydajność** - mniej overhead (brak fork/exec)

### ⚠️ Uwagi:
- **Rebase** - go-git nie ma built-in rebase (używamy force push dla operator-managed branches)
- **Testowanie** - wymaga testów z prawdziwym Bitbucket Server
- **Debugging** - może być trudniejsze niż CLI (brak `git log`, `git status` w terminalu)

## Testowanie z Bitbucket Server

### Przed wdrożeniem:
1. ✅ Testy jednostkowe z mock repository
2. ✅ Testy integracyjne z lokalnym repozytorium Git
3. ✅ Testy E2E z Bitbucket Server on-premise
4. ✅ Weryfikacja wsparcia dla `multi_ack`

### Scenariusze testowe:
- Clone z różnych wersji Bitbucket Server
- Fetch z dużymi repozytoriami
- Push z konfliktami
- Push nowych branchy
- Reset do remote branch

## Status

- [ ] Migracja `go.mod` na `fluxcd/go-git`
- [ ] Implementacja `cloneGitRepoUsingLibrary`
- [ ] Implementacja `checkoutBranchUsingLibrary`
- [ ] Implementacja `commitAndPushUsingLibrary`
- [ ] Implementacja `fetchLatestChangesUsingLibrary`
- [ ] Implementacja `resetToRemoteBranchUsingLibrary`
- [ ] Aktualizacja `reconciliation_single.go`
- [ ] Aktualizacja `reconciliation_cleanup.go`
- [ ] Testy jednostkowe
- [ ] Testy E2E z Bitbucket Server
- [ ] Usunięcie `git_cli.go` (po weryfikacji)

## Referencje

- [go-git Documentation](https://pkg.go.dev/github.com/fluxcd/go-git/v5)
- [FluxCD Blog: Flux puts the Git into GitOps](https://fluxcd.io/blog/2022/03/flux-puts-the-git-into-gitops/)
- [Bitbucket Server Git Protocol](https://confluence.atlassian.com/bitbucketserver/git-protocol-847136940.html)

