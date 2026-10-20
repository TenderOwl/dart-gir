---
title: BSD 3-Clause
description: dart-gir is licensed under the BSD 3-Clause License, copyright 2026 Andrey Maksimov. Full license text and practical guidance on using it.
nav_order: 6
nav_label: License
section_label: Licence
---

dart-gir is released under the BSD 3-Clause License — a permissive licence that lets you use, modify and redistribute the code, including commercially, with one obligation: keep the copyright notice.

:::{meta}
{{facts.license}} · Copyright © 2026 Andrey Maksimov · [LICENSE on GitHub →](https://github.com/TenderOwl/dart-gir/blob/main/LICENSE)
:::

## What you can do with it

:::{cols}
### Permitted, without asking

- Use it in personal or commercial software
- Modify it, and ship your modified version
- Redistribute it in source or binary form
- Use it in closed-source and proprietary projects
- Use it as the basis for a different binding generator

### The one obligation

- Retain the copyright notice, the condition list and the disclaimer in redistributions of source
- Reproduce them in the documentation or other materials of a binary redistribution

The licence does *not* permit using the author's name or the names of contributors to endorse or promote a derived product. If you want that, ask.
:::

:::{note} About the generated packages
The BSD-3-Clause licence covers this project's own code — the generator, the handwritten `package:gir_ffi` runtime helpers, the tests, the example app and the documentation — including the Dart code the generator emits. It does not relicense the native libraries your application links against. GLib, GTK and libadwaita are LGPL, and the GPL-covered parts of the GNOME stack carry their own terms; that is between you and the toolkit, not something this licence changes.
:::

## Full license text

```text title=LICENSE
{{facts.license_text}}
```

The authoritative copy is the [LICENSE file in the repository](https://github.com/TenderOwl/dart-gir/blob/main/LICENSE). No warranty is provided — the `AS IS` disclaimer above is part of the licence, not a formality. The project is pre-1.0 and its API is still moving.

## Attribution

BSD-3-Clause does not require a credit line in your application's user interface, but it does require the notice to travel with redistributions. In practice that means:

| You are… | What to do |
| --- | --- |
| Depending on the packages from a fork or a path dependency | Nothing beyond keeping the `LICENSE` file in the distribution. |
| Redistributing generated bindings in your own source tree | Keep the copyright notice and BSD-3-Clause terms alongside them — a `LICENSE` file in the vendored directory is enough. |
| Shipping a compiled binary | Reproduce the notice and disclaimer in your documentation or an about/licences screen. |
| Building a commercial product on top of it | Permitted, with the same notice requirement. No source-release obligation, no copyleft, no revenue share. |

## One more thing worth knowing

The native libraries this project binds are not part of this licence. If you ship a GTK application, you are also making LGPL-licensed and sometimes GPL-licensed decisions about how you link and distribute GTK itself, and dynamic versus static linking can change those obligations. This project cannot advise on that — check the terms of the specific libraries you link.

- [View the repository](https://github.com/TenderOwl/dart-gir) →
- [About how this was built](about.html#ai-assisted-development) →
