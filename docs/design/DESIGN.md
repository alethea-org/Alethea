# Editorial Design System

The visual language that ships Alethea's app and marketing surfaces.
This document is the **source of truth**. The CSS file
`priv/static/assets/css/editorial.css` is the implementation.

If a token, component, or rule here disagrees with the CSS, this doc
wins. Future engineers should extend the system here, then let the
CSS follow.

---

## Overview

Alethea's surfaces are quietly editorial. The base atmosphere is
white canvas, dark ink type, generous whitespace, and a near-black
pill CTA — nothing is fighting for attention until a section needs
to. The brand voltage doesn't come from gradient washes or accent
walls; it comes from **full-bleed signature cards** in coral, forest,
and surface-dark that punctuate long-scroll explainer pages every
two or three screens. Between those signature bands, the page reads
like a print magazine: a headline, supporting copy, a small image
cluster, then breathing room.

Type voice is Haas Grotesk at modest weights (400 for display, 500
for sub-titles and buttons). Display headlines never go bolder than
500 — emphasis comes from size and color contrast, not from weight.
Body copy stays at 14px / 400 throughout. The pricing surface runs
its own dialect: **Inter Display** at unusual mid-weights (475 /
575) and **pill-shaped buttons** that don't appear on any other
page — a deliberate sub-system signaling "this page is about
commercial precision."

### Key Characteristics

- **Primary CTA** is `--colors-primary` (near-black ink) with white
  text and a `--rounded-lg` (12px) corner — it reads as confident
  and final, never decorative.
- **Secondary CTA** is a `--colors-canvas` button with `--colors-ink`
  text and a hairline outline. The two together form the signature
  button pair.
- **Hero** is white canvas. There is no atmospheric gradient, no
  mesh, no background flourish. The brand strength comes from the
  type and the buttons sitting in clean whitespace.
- **Brand voltage** lives in signature surface cards: coral, forest,
  and surface-dark carry full-bleed product callouts every few
  screens.
- **Demo-card grids** carry product UI fragments on peach, mint,
  cream, and other warm pastel surfaces.
- **Section rhythm**: white canvas → coral signature card → white
  body → cream callout band → dark navy CTA → light gray CTA banner
  → footer. The canvas resets between every signature surface.
- **Border radius** is hierarchical: `--rounded-lg` (12px) for
  primary CTAs and large signature cards, `--rounded-md` (10px) for
  content cards and demo grids, `--rounded-sm` (6px) for inputs,
  `--rounded-full` for icon buttons. Pricing buttons jump to
  `--rounded-pill` to mark themselves as a separate dialect.
- **Vertical rhythm** is `--spacing-section` (96px) between major
  bands — universal across every page.

---

## Colors

All colors are CSS custom properties on `:root`. Selectors never
carry a raw hex; they read from a token.

### Brand & Accent

| Token                        | Hex      | Use                                                        |
| ---------------------------- | -------- | ---------------------------------------------------------- |
| `--colors-primary`           | `#181d26`| Primary CTA background, h1/h2 display, surface-dark band.  |
| `--colors-primary-active`    | `#0d1218`| Press state on primary buttons.                            |

### Surface

| Token                              | Hex      | Use                                                          |
| ---------------------------------- | -------- | ------------------------------------------------------------ |
| `--colors-canvas`                  | `#ffffff`| Default page surface; the floor of every editorial body.     |
| `--colors-surface-soft`            | `#f8fafc`| Tabbed feature cards, the featured pricing tier.             |
| `--colors-surface-strong`          | `#e0e2e6`| Light gray "Start building with Alethea" CTA banner near footer.|
| `--colors-surface-dark`            | `#181d26`| Dark navy mid-page CTA cards.                                |
| `--colors-surface-dark-elevated`   | `#1d1f25`| Articles-page hero base behind the rainbow-stripe overlay.   |
| `--colors-hairline`                | `#dddddd`| 1px border for input outlines, table dividers, secondary outlines.|

### Text

| Token                       | Hex      | Use                                                       |
| --------------------------- | -------- | --------------------------------------------------------- |
| `--colors-ink`              | `#181d26`| Strongest text — h1/h2 display, primary button text-on-light.|
| `--colors-body`             | `#333840`| Default running-text color.                               |
| `--colors-muted`            | `#41454d`| Footer links, breadcrumbs, captions.                      |
| `--colors-border-strong`    | `#9297a0`| 1px outline color on disabled secondary buttons.          |
| `--colors-on-primary`       | `#ffffff`| Text color on primary buttons and dark surfaces.          |
| `--colors-on-dark`          | `#ffffff`| Text color on signature dark surfaces.                    |
| `--colors-on-dark-soft`     | `#9297a0`| Secondary text on dark surfaces.                          |
| `--colors-pricing-ink`      | `#181d26`| Type color on the pricing surface. Same value as `--colors-ink`, named separately so the pricing dialect can diverge without touching the editorial text roles. |

### Signature Card Surfaces

These are the brand's voltage moments. Each is a full-bleed surface
that the editorial rhythm drops every two or three screens.

| Token                            | Hex      | Use                                                        |
| -------------------------------- | -------- | ---------------------------------------------------------- |
| `--colors-signature-coral`       | `#aa2d00`| Largest signature card on the homepage. Dark coral with white type. |
| `--colors-signature-forest`      | `#0a2e0e`| Deep-green signature card in the homepage demo-grid cluster.|
| `--colors-signature-cream`       | `#f5e9d4`| Cream callout band — soft beige surface for dark type and product UI fragments.|
| `--colors-signature-peach`       | `#fcab79`| Demo-card surface for small product UI fragments.           |
| `--colors-signature-mint`        | `#a8d8c4`| Demo-card surface for small product UI fragments.           |
| `--colors-signature-yellow`      | `#f4d35e`| Demo-card surface for small product UI fragments.           |
| `--colors-signature-mustard`     | `#d9a441`| Demo-card surface for small product UI fragments.           |

### Semantic

| Token                          | Hex      | Use                                                       |
| ------------------------------ | -------- | --------------------------------------------------------- |
| `--colors-link`                | `#1b61c9`| Inline body links and anchor text. **Not** the primary button color. |
| `--colors-info`                | `#254fad`| Info callouts.                                            |
| `--colors-info-border`         | `#458fff`| Info borders; input focus border.                         |
| `--colors-success`             | `#006400`| Success text / icons.                                     |
| `--colors-success-border`      | `#39bf45`| Success borders.                                          |
| `--colors-success-soft`        | `#edf4ed`| Success soft surface (e.g. OK pill).                      |
| `--colors-danger`              | `#aa2d00`| Danger text / icons.                                      |
| `--colors-danger-soft`         | `#f7ece7`| Danger soft surface (e.g. risk chip background).          |
| `--colors-warn`                | `#d9a441`| Warning text / icons.                                     |
| `--colors-warn-soft`           | `#fdf6e7`| Warning soft surface.                                     |

### Pill border tones

Pill components combine a soft surface with a stronger edge that
isn't otherwise used in the system. Extracted to keep the edge tone
in `:root`:

- `--colors-pill-border-ok` (`#abefc6`)
- `--colors-pill-border-warn` (`#fedf89`)
- `--colors-pill-border-danger` (`#fecdca`)
- `--colors-pill-border-neutral` (`#d5dde5`)

---

## Typography

### Font Family

Haas Grotesk, with a fallback to `-apple-system, BlinkMacSystemFont,
"Segoe UI", Roboto, ...`. The pricing surface runs a separate
**Inter Display** stack at mid-weights (475 / 575).

Alethea does not license Haas, so the app ships the spec's documented
substitute: **Inter** as a variable font (`wght@100..900`) from Google
Fonts, loaded by every layout. Being variable is the requirement, not
a nicety — the pricing dialect's 475 / 575 mid-weights round to 500 on
a static face. `body` sets the stack once in `app.css`; no component
re-declares a family except `.pricing-surface`, which opts its subtree
into the pricing dialect.

### Hierarchy

Every row below is four tokens, not one:
`--typography-<step>-size`, `-weight`, `-leading`, `-tracking`. The
`.t-*` classes are pure token references, so retuning a step is a
`:root` edit and never a hunt through selectors.

| Token                          | Size      | Weight | Line Height | Letter Spacing | Use                            |
| ------------------------------ | --------- | ------ | ----------- | -------------- | ------------------------------ |
| `t-display-xl`                 | 48px      | 500    | 1.1         | 0              | Articles page h2               |
| `t-display-lg`                 | 40px      | 400    | 1.2         | 0              | Homepage h1 hero               |
| `t-display-md`                 | 32px      | 400    | 1.2         | 0              | Platform-page h2               |
| `t-title-lg`                   | 24px      | 400    | 1.35        | 0.12px         | Section titles                 |
| `t-title-md`                   | 20px      | 400    | 1.5         | 0              | Sub-section titles             |
| `t-title-sm`                   | 18px      | 500    | 1.4         | 0              | Article-card titles            |
| `t-label-md`                   | 16px      | 500    | 1.4         | 0              | Demo-card titles               |
| (button)                       | 16px      | 500    | 1.4         | 0              | Standard CTA button labels     |
| `t-pricing-display`            | 44.8px    | 475    | 1.1         | 0              | Pricing-page h1                |
| `t-pricing-section`            | 28px      | 475    | 1.2         | 0              | Pricing-page section heads     |
| `t-body-md`                    | 14px      | 400    | 1.25        | 0              | Body copy, footer links, top-nav items |
| `t-caption`                    | 14px      | 500    | 1.35        | 0.16px         | Captions and meta text         |
| `t-legal`                      | 13.12px   | 600    | 1.2         | 0              | Cookie/legal CTA buttons       |
| (pricing card title)           | 20px      | 475    | 1.3         | 0              | Pricing tier card plan name    |

### Principles

The system prefers weight 400 for display sizes — a 40px h1 is
**not** bold. Visual emphasis is delegated to size, color contrast,
and the signature surface cards. Where the system does want weight,
it pivots to 500 (sub-titles, buttons, article titles), never 600
or 700 in the editorial body. The only true bold (600) lives in
`t-legal` — boldness is reserved for terms-of-service surfaces.

The dashboard's `.pt-h1` and `.pt-h2` are not a parallel scale. They
are grouped selectors on `t-display-lg` and `t-title-lg`, so the page
title and the section/card titles land on the same steps as any other
surface. A template can use either name; there is one definition per
step.

---

## Layout

### Spacing System

- **Base unit:** 4px.
- **Tokens:** `--spacing-xxs` 4px · `--spacing-xs` 8px ·
  `--spacing-sm` 12px · `--spacing-md` 16px · `--spacing-lg` 24px ·
  `--spacing-xl` 32px · `--spacing-xxl` 48px ·
  `--spacing-section` 96px.
- **Section padding (vertical):** `--spacing-section` (96px) is the
  universal vertical rhythm constant.
- **Card internal padding:** `--spacing-xl` (32px) for tabbed
  feature cards; `--spacing-xxl` (48px) inside signature coral /
  forest / dark cards; `--spacing-lg` (24px) for cream callouts and
  demo-grid cards.
- **Gutters:** `--spacing-lg` (24px) between cards in 3-up grids.

### Grid & Container

- **Max content width:** ~1080px (landing), ~1040px (dashboard
  reading column).
- **Editorial body:** Single 8/12-column at large breakpoints,
  collapsing to single-column on mobile.

### Whitespace Philosophy

Alethea uses whitespace as the dominant atmospheric tool. Hero
sections sit in 96px+ of pure whitespace above and below the
headline + sub-headline pair, with no decoration in that whitespace.
The system trusts whitespace alone to do the framing.

---

## Elevation & Depth

| Level              | Treatment                                    | Use                              |
| ------------------ | -------------------------------------------- | -------------------------------- |
| Flat               | No shadow, no border                         | Body sections, top nav, footer.  |
| Soft hairline      | 1px `--colors-hairline` border               | Inputs, sub-nav rails, secondary buttons. |
| Button rest        | Solid `--colors-primary`, no shadow          | Primary CTA buttons.             |
| Card flat          | No shadow; relies on color contrast against the surface band | Signature coral / forest / dark cards, cream callouts. |

The elevation philosophy is **color-block first, shadow second**.
Shadows are minimal; depth is delegated to the contrast between
white canvas and signature surface cards.

Only three surfaces genuinely leave the page, and each reads its
shadow from a token so no selector carries a raw color literal:

| Token              | Use                                                   |
| ------------------ | ----------------------------------------------------- |
| `--shadow-lifted`  | The landing's product-screenshot mock.                |
| `--shadow-overlay` | Floating shell overlays — the topbar user menu.       |
| `--shadow-modal`   | Modal dialogs — the Telegram invite modal.            |

---

## Shapes

| Token            | Value    | Use                                                |
| ---------------- | -------- | -------------------------------------------------- |
| `--rounded-xs`   | 2px      | Cookie-consent and legal CTA buttons.              |
| `--rounded-sm`   | 6px      | Text inputs, small inline buttons.                 |
| `--rounded-md`   | 10px     | Secondary content cards, article cards, cream callouts. |
| `--rounded-lg`   | 12px     | Primary CTA buttons, signature surface cards, tabbed feature cards. |
| `--rounded-pill` | 9999px   | Pricing-page CTA buttons (sub-system only).        |
| `--rounded-full` | 9999px   | Circular icon buttons, avatar surfaces.            |

---

## Components

### Buttons

**`.button-primary`** — Background `--colors-primary` (near-black),
text `--colors-on-primary`, weight 500, padding `--spacing-md`
× `--spacing-lg`, rounded `--rounded-lg` (12px). Active state
darkens to `--colors-primary-active` (`#0d1218`).

**`.button-secondary`** — Background `--colors-canvas`, text
`--colors-ink`, weight 500, rounded `--rounded-lg` (12px), 1px
hairline outline. Sits next to `.button-primary` as the
"less-committed" choice.

**`.button-secondary-on-dark`** — Same shape as
`.button-secondary` but used on signature coral / forest / dark
surfaces.

**`.button-pricing-pill`** — Pricing-page CTA family. Background
`--colors-canvas`, text `--colors-ink`, rounded `--rounded-pill`
(9999px), padding `--spacing-sm` × `--spacing-lg`. The only place
pill-shape appears in the marketing system.

**`.button-legal`** — Cookie-consent and legal-banner CTAs.
Background `--colors-link`, text `--colors-on-primary`,
`t-legal` typography, rounded `--rounded-xs` (2px), padding
`--spacing-sm` × 10px.

**`.button-icon-circular`** — 40px × 40px circular button with
`--colors-canvas` background, hairline border, and `--colors-ink`
icon.

**Size and width modifiers** — `--sm` tightens padding to
`--spacing-xs` × `--spacing-sm` and drops the radius to
`--rounded-md`, for toolbars and card footers; `--block` makes the
button fill its column, for the auth forms. Both keep the role's
colors and type step: the box changes, the voice does not. A disabled
button drops to 50% opacity and, on the secondary, to a
`--colors-border-strong` outline.

### Cards & Containers

**`.hero-band`** — Full-page-width white-canvas hero. No surface
card, no border, no shadow, no atmospheric gradient. Vertical
padding `--spacing-section` (96px).

**`.signature-coral-card`** — Full-bleed coral card. Background
`--colors-signature-coral` (`#aa2d00`), text `--colors-on-primary`,
rounded `--rounded-lg` (12px), internal padding `--spacing-xxl`
(48px). Carries an h2 in display-md, supporting copy in body-md,
and `.button-secondary-on-dark` as the CTA.

**`.signature-forest-card`** — Deep green signature card
(`--colors-signature-forest` `#0a2e0e`). Same shape as the coral
card.

**`.hero-card-dark`** — Dark navy mid-page CTA card. Background
`--colors-surface-dark` (`#181d26`), text `--colors-on-dark`,
rounded `--rounded-lg` (12px), internal padding `--spacing-xxl`
(48px).

**`.feature-card-tabbed`** — Light-cream cards. Background
`--colors-surface-soft`, rounded `--rounded-lg` (12px), internal
padding `--spacing-xl` (32px). Left rail carries vertically-stacked
tab labels; right pane shows the active tab's content.

**`.cream-callout-card`** — Beige callout cards
(`--colors-signature-cream`). Rounded `--rounded-md` (10px),
internal padding `--spacing-lg` (24px).

**`.demo-grid-card`** — Multi-card grids. Background
`--colors-canvas`, rounded `--rounded-md` (10px), internal padding
`--spacing-md` (16px). Each card frames a product UI fragment.

**`.signature-peach-card`, `.signature-mint-card`,
`.signature-yellow-card`, `.signature-mustard-card`** — Demo-card
surfaces that carry small product UI fragments inside multi-card
grid sections. Same shape as `.demo-grid-card` but in their
respective pastel color.

**`.cta-band-light`** — The light gray CTA strip near the footer.
Background `--colors-surface-strong` (`#e0e2e6`), text
`--colors-ink`, rounded `--rounded-lg` (12px), padding
`--spacing-xxl` (48px).

**`.pta-briefing`** — The dashboard's signature surface. Background
`--colors-signature-cream`, rounded `--rounded-lg` (12px), a 3px
`--colors-primary` rail on the left to anchor the reading column, and
no outline: like every signature card it is flat and lets the color
contrast against the white canvas carry it. This is the one band that
breaks the dashboard's white rhythm, which is exactly the pacing rule
the Don'ts describe.

### Inputs & Forms

**`.text-input`** — Standard text input. Background
`--colors-canvas`, text `--colors-ink`, `t-body-md` typography,
rounded `--rounded-sm` (6px), padding `--spacing-sm` ×
`--spacing-md`, height 44px. 1px hairline border in
`--colors-hairline`. Focus state recolors the border to
`--colors-info-border`.

**`.text-input--compact`** — Density modifier. Drops the fixed
height and tightens padding and type for the dashboard's setup forms,
which run denser than the marketing surfaces. Composes with
`.text-input`; it is not a second input component.

**`.text-input--multiline`** — The textarea variant. Adds vertical
resize, a looser line-height and inherited font family.

### Pricing Sub-System

The pricing surface is a deliberate dialect, opt-in at the wrapper:
put **`.pricing-surface`** on the page root and the whole subtree
picks up `--typography-pricing-family` (Inter Display). The
mid-weights 475 / 575 only resolve against a variable font, so the
stack leads with the variable family and the fallbacks degrade to 500.

**`.t-pricing-display`** / **`.t-pricing-section`** — The dialect's
two display steps (44.8px / 475 and 28px / 475).

**`.pricing-tier-card`** — Standard tier card. Background
`--colors-canvas`, text `--colors-pricing-ink`, plan name in
pricing-card title typography (20px / 475), rounded `--rounded-md`
(10px), internal padding `--spacing-xl` (32px).

**`.pricing-tier-card--featured`** — The featured tier. Background
shifts to `--colors-surface-soft`. No accent border, no badge — the
background tone shift is the only signal.

Nothing in the app consumes these yet; there is no pricing page. They
exist so the first pricing surface does not have to re-decide the
dialect.

### Navigation Variants

**`.ptl-nav`** — 68px-tall white bar pinned to the top of every
landing page. Brand mark sits at left; primary horizontal menu
sits center-left in body-md; the right cluster carries the
secondary nav link and the primary CTA. The nav stays light on
every page.

**`.cta-band-light`** — Light surface CTA band near the footer.
Carries an h2 in display-md and a `.button-primary`.

**`.ptl-footer`** — The landing's single privacy line. Muted body
type on canvas, no rule above it.

### App Shell

`app.css` positions the shell — sidebar, topbar, content column, auth
grid — and reads every color, radius and spacing value straight from
the tokens. It no longer carries a palette of its own, so the earlier
re-skin block at the end of `editorial.css` is gone: there is nothing
left to override. What remains in `editorial.css` is the chrome that
is a component rather than a layout (the user menu) plus the shell's
pointer feedback.

**`.app-sidebar__logo`** — The brand mark: a `--colors-primary`
square. `logo.svg` paints with `stroke="currentColor"`, but the shell
loads it through `<img src>` — an isolated document that does **not**
inherit the surrounding `color`. The glyph is forced white with a
filter; removing that filter makes it fall back to black and vanish
into the ink.

**`.app-usermenu`** and its parts (`__trigger`, `__panel`, `__head`,
`__name`, `__email`, `__item`, `__item--danger`, `__foot`) — The
topbar dropdown. `--shadow-overlay` for the lift, hairline dividers,
`--colors-danger` for the sign-out row.

### Icons

`AletheaWeb.Icons` draws the whole set inline as 24×24 stroked SVG at
stroke-width 1.5, round caps and joins. The call site keeps the
project convention (`<.icon name="hero-users" />`); only the
implementation changed.

This is a correctness fix as much as a style one. The old `icon/1`
emitted `<span class="hero-users">` and depended on a Tailwind plugin
to paint a mask into it. The app ships no Tailwind build, so every
glyph outside the handful the fallback sheet happened to include
rendered as an empty span — the sidebar, the search field, the
notification bell and the form icons were all invisible.

Color comes from `currentColor`; size from a class — `.icon` is the
16px default, with `.size-3` / `-4` / `-5` / `-6` for the other steps.
An inline `style` still wins over both.

### Application Surfaces

These components have no counterpart in the marketing spec: they are
the product's own surfaces, built from the documented roles rather
than from new ones.

**`.auth-panel` / `.auth-form-side`** — The login and register split.
An ink `--colors-surface-dark` signature panel on the left and the
white form canvas on the right, with nothing between them. Below
1024px the grid collapses to one column and the panel keeps only its
brand line and headline. This replaces a centered card that stacked
three shadows on a radial-gradient backdrop — both forbidden by the
elevation and hero-atmosphere rules.

**`.field` / `.field__label` / `.field__hint` / `.field__error`** —
The form stack around `.text-input`. One label treatment (uppercase
caption in `--colors-muted`), one hint treatment, one error treatment
in `--colors-danger`. `.text-input--error` recolors the control's
border; nothing else changes, so an invalid field never becomes a
different component.

**`.cmdbar`** — One horizontal control row: search, result count,
filter popover, sort. It is the answer to a real defect in the
dashboard's first version, where the picker stacked five rows of
chrome above a caseload that was often a single patient. The filter
chips live behind `.filter-menu`, whose trigger carries a
`.filter-badge` with the active count, so an untouched filter set
costs one control instead of a row.

**`.patient-grid` / `.patient-card`** — The caseload as demo-grid
cards: avatar, alias, schedule line, then a hairline foot with a
`.status-dot` and its label. `--on` marks the patient currently in
the briefing; `--risk` swaps the surface to `--colors-danger-soft`.
`.patient-card--new` is the dashed create affordance and always sits
last. Both the dashboard picker and the patients page render the same
component, so the caseload reads identically in both places.

**`.stat-strip` / `.stat-tile`** — Flat counters divided by hairlines,
the same construction as the briefing metric strip. No icon, no
accent, no shadow.

**`.meter`** — The emotion trend bar. Replaces the CDN progress
element; the fill modifiers (`--joy`, `--sadness`, `--anger`,
`--fear`, `--neutral`) map onto the signature palette in the same
pairing the 7-day chart uses, so a trend reads the same color in both
places.

**`.chat-line` / `.chat-bubble`** — The decrypted clinical history.
Inbound is a hairline bubble on canvas, outbound is ink. Two roles,
no third.

**`.data-table`** — The operational surface (the job queue). Hairline
dividers, a `--colors-surface-soft` header row, and `.data-table__mono`
for argument payloads. `.link-button` is the in-row action: link-blue
by default, `--danger` and `--ok` for the destructive and recovery
actions.

**`.notif`** — The notification bell and its panel. Severity is a
`.status-dot` role (`--risk` / `--warn` / `--info`), never a bespoke
hex, so a new alert level is a role decision.

**`.flash` / `.flash-stack` / `.notice`** — Toast and inline notice.
Both are the card's shape with a semantic border; the system
documents no toast component, so neither invents an accent.

**`.empty-state`** — A hairline frame with an icon, a title and one
sentence. It replaces the dashed novelty boxes the app used to draw
around empty regions.

**`.band` / `.signature-split` / `.demo-grid` / `.footer-cols`** — The
landing's rhythm helpers. `.band` is the 96px vertical constant; the
surface modifier decides which documented surface a band sits on.

**`.error-page`** — The 404 / 500 surface. A hero band holding
nothing but type and the button pair. The templates are complete HTML
documents because error rendering is configured with `layout: false`.

### Dashboard

`.pta-metric*`, `.pta-emotion*`, `.pta-field-title`, `.pta-label`,
`.pta-hint*`, `.pta-chatlog*`, `.pta-modal*`, `.pta-code*` and
`.pta-nudge*` carry the dashboard's own surfaces. They exist because
the templates used to inline all of it on the Tailwind slate / amber /
indigo ramp; every color now resolves through a token.

The two bot-config nudges are role-coded: `.pta-nudge--crisis` speaks
with `--colors-warn`, `.pta-nudge--welcome` with `--colors-info` over
a soft surface. The welcome card previously used Tailwind indigo,
which the editorial chrome rules out.

---

## Do's and Don'ts

### Do

- Keep `.button-primary` near-black. The brand's primary CTA is
  `--colors-primary`, not the link blue. Mixing them up turns a
  confident hero into a confused one.
- Reserve `.button-primary` for one primary action per viewport.
  The system is designed for scarcity at the brand-action layer.
- Use `.button-secondary` (white with hairline outline) as the
  natural pair with `.button-primary`.
- Trust whitespace as the hero atmosphere. Hero bands are
  intentionally calm — no gradient, no mesh, no atmospheric
  backdrop.
- Use `.signature-coral-card`, `.signature-forest-card`, and
  `.hero-card-dark` to break editorial monotony. These are the
  brand's voltage moments.
- Keep `.demo-grid-card` heights uneven within a grid. Uniform
  heights feel like a spec sheet.
- Treat the pricing surface as its own dialect: keep the
  pricing-display, pricing-section, pricing-card-title type and
  `.button-pricing-pill` together. Mixing them with the editorial
  body type breaks the sub-system's voice.
- Anchor every editorial band with `--spacing-section` (96px)
  vertical padding.

### Don't

- Don't make `--colors-link` (`#1b61c9`) the primary button color.
  It is the link color. The primary button is `--colors-primary`
  (`#181d26`, near-black). Treating link-blue as the brand action
  is the most common mistake when reading the CSS variables.
- Don't add a gradient backdrop to the hero. The hero is white,
  full stop. Mesh, aurora, spotlight gradients all read as "another
  SaaS template."
- Don't bold display-weight type. `t-display-xl` and `t-display-lg`
  are intentionally weight 400 / 500 — going to 700 reads as
  marketing-page-template.
- Don't use `--rounded-pill` outside the pricing surface. It's a
  sub-system signal, not a general radius option.
- Don't repeat the same surface mode in two consecutive bands. The
  editorial pacing depends on rhythm: white → signature card →
  white → cream → dark → white. Two whites in a row read as a
  typography blog.
- Don't add hover state styling beyond what the system already
  encodes. The system documents Default and Active/Pressed only.
- Don't introduce additional accent colors beyond the documented
  signature card palette.
- Don't write raw hex values in templates. Every color reference
  must resolve through a token.

---

## Known Gaps

- **Hover behavior** across all components is not documented (per
  global no-hover policy). The one exception is the authenticated
  shell, which already carried hover feedback on its nav and menu
  rows before this system existed; the editorial block re-skins those
  states rather than removing them. Spec components — buttons, cards,
  inputs — document Default and Active/Pressed only.
- **Animation and transition timings** are not in scope. The user
  menu's entrance animation is pre-existing shell chrome; its
  keyframes live in `app.css`.
- **`--colors-pricing-ink`** is referenced by the upstream spec
  without a defined value. It is an alias of `--colors-ink` here.
- **No CSS framework.** The FlyonUI CDN and the generated
  `default.css` (daisyUI's fallback sheet) are gone, along with every
  `btn`, `badge`, `progress-*`, `stat-*` and `chat-bubble-*` class
  that read from their palettes. `app.css` and `editorial.css` are the
  only stylesheets the app loads, so a class that is not in one of
  them paints nothing — which makes an unstyled element a visible bug
  instead of a silent one.
- **The CSS variable `--theme_button-background-primary:
  #1b61c9`** exists at `:root` upstream of Airtable's design
  library but is not used as the primary CTA color anywhere. It
  maps to the link/info color role instead. Documented here so
  future extractions don't re-trip over the misleading variable
  name.
- **Dark mode** is not part of the editorial system. The dashboard
  already carries a light-mode-only constraint per the project
  manifest; the marketing system follows.

---

## Migration from `--pt-*` namespace

PR #170 (issue #164) renamed every `:root` token from the
prototype-era `--pt-*` namespace to the Airtable-aligned
`--colors-*` / `--spacing-*` / `--rounded-*` / `--typography-*`
namespaces documented above. Class names (`.pt-card`, `.pt-h1`,
`.pta-briefing`, `.ptl-cta`, `.app-sidebar`, …) stayed readable for
the templates; only the variable references inside the CSS file
moved.

A follow-up finished the parts that landed as tokens without a
consumer: the type scale gained its weight / leading / tracking axes
and `.pt-h1` / `.pt-h2` were grouped onto it, the briefing became the
cream signature surface, the pricing dialect gained its font stack and
display steps, and the dashboard and shell templates stopped inlining
raw hex.

Templates should reference tokens through class names (`.pt-card`,
`.button-primary`, etc.), not through inline `style` attributes or
inline `var(--colors-…)` references. The system is the abstraction
layer; templates should not bypass it. Layout-only inline styles
(grid, flex, width) remain in some templates — those carry no color
and are a separate cleanup.
