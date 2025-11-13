/*
Copyright 2025.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package networkpolicy

// Note: This file has been refactored into specialized modules for better organization:
//
// - git_credentials.go: Git credentials retrieval from Kubernetes Secret
// - git_cli.go: Git CLI operations (clone, checkout, commit, push)
// - git_file_operations.go: File operations in Git repository (read, write, exists, list)
// - git_api.go: Git provider API operations (PR, merge, delete branch, HTTP requests)
//
// All functions have been moved to the appropriate specialized modules. This file is kept
// for reference and to maintain backward compatibility during migration.





