---
name: use-reference-repos
description: Pull and inspect open-source reference code under .repos. Use when the user asks to examine code from an upstream project, when debugging or implementing an integration would benefit from reading dependency source, or when comparing Codevisor behavior with another open-source project.
---

# Use reference repositories

Use `.repos` for open-source source-code references. Do not use the old refs CLI or a `references` directory.

Feel free to fetch reference code whenever it would improve the work. This is pre-authorized: do not ask the user before initializing an existing reference submodule or adding a useful open-source repository as a new submodule.

## Use an existing reference

Check `.gitmodules`, then initialize only the repository needed:

```sh
git submodule update --init .repos/<repository>
```

The pinned commit is usually the right starting point. If current upstream code matters, fetch it normally and inspect the remote branch:

```sh
git -C .repos/<repository> fetch origin
```

## Add a reference

When a useful project is not listed, add its official upstream repository directly:

```sh
git submodule add https://github.com/<owner>/<repository>.git .repos/<repository>
```

Adding the submodule and `.gitmodules` entry is an intended repository change. Keep reference names short and match the upstream repository name unless that would be ambiguous.

## Rules

- Pull the references relevant to the task; do not initialize every submodule by default.
- Treat reference repositories as upstream source to inspect. Do not edit their contents unless the user explicitly asks to modify or contribute to that project.
- Prefer source inspection over guessing when behavior depends on an upstream implementation.
- Report the upstream repository and commit used when the answer or implementation materially depends on it.
