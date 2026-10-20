# The site pipeline

The project site is generated. This document is the specification: what
the sources look like, what the generator guarantees, and what a change
to either side has to respect.

## The shape of it

```
site_src/                       the sources (committed)
  pages/*.md                    one Markdown file per page
  data/packages.json            the curated package list
  data/facts.json               the derived facts (committed, generated)
  assets/style.css              the design system

tool/
  build_site.dart               renders site_src/ → site/
  collect_facts.dart            derives site_src/data/facts.json
  site/                         the generator library
    markdown.dart               the Markdown subset
    frontmatter.dart            the front-matter reader
    directives.dart             the :::{name} block directives
    layout.dart                 the page shell
    components.dart             the design system's components
    facts.dart                  facts loading, the skip report, aggregation
    highlight.dart              the code tokeniser

site/                           the output (committed)
  *.html                        written by tool/build_site.dart
  assets/style.css              copied from site_src/assets/
  docs/                         written by tool/build_api_docs.dart (gitignored)
```

`site_src/` is a plain directory, not a package: it has no
`pubspec.yaml`, so it does not join the Dart workspace. The same rule
that keeps `example/` package-free.

## The output is committed

Two reasons, and they pull in the same direction.

The site stays browsable on GitHub without a build — a visitor can read
the pages, and a GitHub preview of a pull request shows the change.
And the generator is not allowed to drift from its output: CI
regenerates the site and fails if the committed copy differs, exactly
the way the repository treats the generated bindings. CI deliberately
does not re-run the *binding* generator — the committed packages are
what gets linted and tested — but the site generator reads nothing but
the repository, so it is reproducible in CI and the drift check is
meaningful.

```
dart run tool/collect_facts.dart   # re-derive site_src/data/facts.json
dart run tool/build_site.dart      # re-render site/
dart run tool/build_site.dart --check   # fail if site/ is stale
```

`tool/build_site.dart` owns `site/*.html` and `site/assets/`. It
deletes them before writing, so a renamed page cannot leave a stale
file behind. It **never touches `site/docs/`**, which
`tool/build_api_docs.dart` owns. The two scripts run in either order.

## No dependencies

The site generator uses only `dart:`. Not a style choice — three
reasons that each independently rule it out:

- `package:markdown` is not in the local pub cache, and the build has
  no network.
- `package:yaml` would force a re-resolution of the workspace's
  `analyzer` constraint and break `dart test` (the same reason
  `tool/build_api_docs.dart` hand-parses the workspace list).
- CI must be able to build the site with nothing but the Dart SDK.

So the Markdown subset is implemented here. It is small on purpose: a
smaller surface is a smaller surface for subtle bugs. The subset is
headings, paragraphs, lists (nested one level), GFM tables, fenced code
blocks with an optional title, block quotes, thematic breaks, and the
inline set — code, strong, emphasis, links, images, autolinks. Raw
HTML *blocks* pass through verbatim, because the design page carries
three inline SVG diagrams that depend on page CSS classes and cannot
become external files without losing that dependency.

## The page format

```markdown
---
title: Features
doc_title: dart-gir — Features
description: What the generator gives you.
nav_order: 2
nav_label: Features
section_label: Feature list
---

The opening paragraph becomes the page's lede.

## The first section

`##` headings become numbered sections and feed the rail's table of
contents.
```

| Key | Meaning |
|---|---|
| `title` | the visible `h1` |
| `doc_title` | the browser title; falls back to `title` |
| `description` | the meta description and `og:description` |
| `nav_order` | the position in the primary navigation |
| `nav_label` | the navigation label; falls back to `title` |
| `section_label` | the kicker line above the `h1` |
| `og_type` | the `og:type` meta value; defaults to `website` |

The front matter is a flat `key: value` list — deliberately smaller
than YAML, so no YAML parser is needed. Values may be quoted.

## The directives

Markdown cannot express the dossier's bespoke blocks, so a small set of
fenced containers is supported:

```
:::{note} Ownership
Text of the note.
:::
```

| Directive | Form |
|---|---|
| `note` | a left-ruled aside. `variant=warn` and `variant=plain` change the rule's colour. |
| `figure` | wraps raw HTML (the SVG diagrams) with an optional caption. |
| `kv` | a label / value fact list. The content is a list of `Label: value` lines. |
| `checklist` | `[x]` and `[ ]` items, rendered with `✓` and `○`. |
| `phase` | a roadmap phase. `status=done\|wip\|next\|future` sets the rule's colour. |
| `cols` | a two-column layout. Each `###` heading starts a new column. |
| `meta` | a single monospace line of derived facts. |
| `packages` | the coverage table, rendered from the curated list and the facts. |

The header carries a name, an optional label and optional `key=value`
attributes. Attributes may sit inside the braces
(`:::{note variant=warn}`) or after them (`:::{note} variant=warn`); both
spellings are accepted. Directives nest.

## The facts layer

`{{facts.…}}` placeholders are substituted from `facts.json` before the
Markdown is parsed. A placeholder that names a fact which does not
exist **fails the build**, with the file and the line. A typo must
never render as an empty string.

| Key | Derivation |
|---|---|
| `total_skipped` | the sum of every package's `Total skipped:` |
| `package_skips.<name>` | one package's skip count |
| `skips.<group>` | the aggregated reason groups — the features page's coverage table |
| `categories.<name>` | the aggregated categories |
| `features.props_classes` | the number of `*_props.dart` files |
| `features.props_accessors` | the number of generated property accessors |
| `features.typed_signals` | the number of generated `onSignalName` helpers |
| `features.async_callbacks` | the number of generated `*Callback` overloads |
| `skip_report_example` | an excerpt of `packages/glib/skip_report.txt`, generated at build time |
| `sdk_constraint` | the root `pubspec.yaml`'s `environment: sdk:` |
| `license` | detected from the `LICENSE` file |
| `license_text` | the `LICENSE` file itself |
| `docs[]` | the files under `docs/` with their line counts |
| `generated_files` / `generated_lines` | the size of the generated tree |
| `generator_files` / `generator_lines` | the size of the generator |

`site_src/data/packages.json` is the **curated** half: the package
list, each package's namespace, native library, role and blurb. It
replaces both the hand-written table on the home page and the
`_packageBlurbs` map that used to live in `tool/build_api_docs.dart` —
one source of truth for the site and the API landing page.

`tool/collect_facts.dart` cross-checks the two: it fails if
`packages.json` names a package that is not in the workspace, or a
namespace the package's `skip_report.txt` contradicts.

### The skip report format

```
# Skip report for package glib (GLib 2.0)
Total skipped: 351

## By category
callable: 332
…

## By reason
introspectable=0: 98
return: string list return type (null): 25
…
```

The header gives the package and its namespace, `Total skipped:` gives
the per-package total, and the two blocks give the category and reason
counts. The reason groups the coverage table is built from are declared
in `tool/site/facts.dart` as `skipGroups`; a reason that matches no
group falls into `other`, and the groups always add up to the total.

## The design system

`site_src/assets/style.css` is one stylesheet with CSS custom
properties, light and dark through `prefers-color-scheme`.

The direction is a **technical dossier, set like an editorial print
document**: the page is the surface, and structure comes from hairline
rules, a 70-character measure and a strict typographic scale — not from
boxes. Three typefaces do the work: a serif for headings, a sans for
prose, a mono for labels, numbers and code. The serif/sans pairing is
the single strongest signal that the site is not a generated landing
page.

The rules the stylesheet holds itself to:

- No border-radius above 2px, no shadows, no gradients, no background
  panels, no emoji, no animated reveals.
- One accent (rust), used for links, the active navigation item, the
  section numbers and the SVG diagrams.
- Every interactive element keeps a visible `:focus-visible` ring.
- The current page is exposed with `aria-current="page"`.

The class vocabulary is small and listed in `tool/site/components.dart`,
which is the whole vocabulary — the old site's `badge`, `btn`, `stat`,
`cell`, `tag` and `phase-head` names are retired.

There are **no web fonts**: the build has no network and GitHub Pages
must not depend on a CDN, so the typography is built from system font
stacks. The stacks degrade to Georgia/Times and the generic mono, and
the layout does not depend on the exact face.

## The API reference

`tool/build_api_docs.dart` runs `dart doc` once per workspace package
into `site/docs/<package>/`, injects cross-package navigation into
every generated page, and writes `site/docs/index.html` through the
same layout as the rest of the site — with a `basePath` of `../`, so
its links and its stylesheet reference resolve from one directory down.

The dartdoc pages themselves are **not** restyled: dartdoc owns that
markup and its CSS. Only the landing page and the injected navigation
are ours. The injected navigation carries its own inline `<style>`,
using the site's palette, because a dartdoc page cannot load the site's
stylesheet without colliding with dartdoc's own.

`site/docs/` is gitignored and is never diffed — `dart doc` output is
not byte-reproducible across SDK versions.

## The tests

`test/site/` holds the site generator's suite:

| File | Covers |
|---|---|
| `markdown_test.dart` | every element of the Markdown subset, the front matter, the directives and the facts substitution |
| `highlight_test.dart` | the tokeniser for Dart, C and shell, and the plain fallback |
| `layout_test.dart` | the shell: masthead, navigation, rail, colophon, `<head>` metadata, base-path handling |
| `facts_test.dart` | the skip-report parser, the aggregation, the curated list's schema, and the byte-stability of the committed `facts.json` |
| `site_output_test.dart` | the drift check — the committed `site/` matches what the generator produces — plus the internal-link check, the anchor check and the "no hard-coded numbers" check |

The link check used to live in CI as an ad-hoc Python snippet. It is now
a Dart test, so it runs on every `dart test` and not only in CI.
