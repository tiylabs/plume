# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> This project is a fork of [ColeMei/pane](https://github.com/ColeMei/pane), forked from upstream
> commit `526dda4` (2026-10-10). Changes made before that commit belong to the upstream project and
> are recorded in its history, not in this file. The entries below cover this fork only. The project was renamed from Pane to Plume after v0.3.1075;
> the older entries and their links still use the former name and repository path `tiylabs/pane`.

## [v0.4.1075] - 2026-10-11
### :sparkles: New Features
- [`6f57f89`](https://github.com/tiylabs/plume/commit/6f57f89ea5ba7a16a92005ee355407dc7956581a) - **settings**: ✨ Halve the panel transparency range and default to 50% *(commit by [@jorben](https://github.com/jorben))*
- [`e2882e0`](https://github.com/tiylabs/plume/commit/e2882e0faf7833b89bc72b0a100c981f41d31a01) - **settings**: ✨ Default panel transparency to 0% *(commit by [@jorben](https://github.com/jorben))*
- [`92c1986`](https://github.com/tiylabs/plume/commit/92c1986aca71f7a17b782ea39585e5f9f35ad93a) - **ui**: ✨ Refresh app and menu bar icons *(commit by [@jorben](https://github.com/jorben))*
- [`28df4ee`](https://github.com/tiylabs/plume/commit/28df4ee8de86d59582015eca30093ce0f99486d4) - **ui**: ✨ Refresh menu bar icon *(commit by [@jorben](https://github.com/jorben))*

### :bug: Bug Fixes
- [`8cae21b`](https://github.com/tiylabs/plume/commit/8cae21bc6c9eb62ca9a52b76c2fd6800e809a119) - **ui**: 🐛 Restore clear glass when the pane loses focus on macOS 27 *(commit by [@jorben](https://github.com/jorben))*

### :wrench: Chores
- [`e5a3a14`](https://github.com/tiylabs/plume/commit/e5a3a14de84b3a29d5292bd78abb6df9db3e3fea) - **cask**: 🔧 Use placeholder version and sha256 in source cask *(commit by [@jorben](https://github.com/jorben))*
- [`7758c61`](https://github.com/tiylabs/plume/commit/7758c614f5a578e95793ec7ddf26ea05a7aa1329) - 🔧 Rename project from Pane to Plume *(commit by [@jorben](https://github.com/jorben))*


## [v0.3.1075] - 2026-10-10
### :sparkles: New Features
- [`09d69c7`](https://github.com/tiylabs/pane/commit/09d69c75f0046a33bfe5edfa81b2217054612a4b) - **ui**: ✨ Add Liquid Glass panel material on macOS 26 *(commit by [@jorben](https://github.com/jorben))*
- [`42751a0`](https://github.com/tiylabs/pane/commit/42751a00961945248aa2ba95a04f2fbfe5c3ea3d) - **ui**: ✨ Add persistent keep-on-top thumbtack to title bar *(commit by [@jorben](https://github.com/jorben))*
- [`b5f5482`](https://github.com/tiylabs/pane/commit/b5f548292fc2dc105b486f7f88594bac65987136) - **ui**: ✨ Hide close dot when pane is unfocused and not hovered *(commit by [@jorben](https://github.com/jorben))*
- [`9ec1db9`](https://github.com/tiylabs/pane/commit/9ec1db907bf8ae4eb442bfe903ba295be42d0ff9) - **ui**: ✨ Add dedicated chrome text colors for title bar and footer *(commit by [@jorben](https://github.com/jorben))*
- [`e71b669`](https://github.com/tiylabs/pane/commit/e71b669c5dfed3dfb6de2fc886d874b705e6bfd3) - **update**: ✨ Repeat the update toast daily until upgraded *(PR [#1](https://github.com/tiylabs/pane/pull/1) by [@jorben](https://github.com/jorben))*

### :bug: Bug Fixes
- [`4a080f0`](https://github.com/tiylabs/pane/commit/4a080f0b4360a68421e275317abeee1e2d437038) - **settings**: 🐛 Silence unused result warning on alert *(commit by [@jorben](https://github.com/jorben))*
- [`07c3902`](https://github.com/tiylabs/pane/commit/07c3902d82e0d0f00fb65afa2ae659315aa46919) - **ui**: 🐛 Stop close dot flashing grey when hovering an unfocused pane *(commit by [@jorben](https://github.com/jorben))*

[v0.3.1075]: https://github.com/tiylabs/pane/compare/v0.2.1075...v0.3.1075
[v0.4.1075]: https://github.com/tiylabs/plume/compare/v0.3.1075...v0.4.1075
