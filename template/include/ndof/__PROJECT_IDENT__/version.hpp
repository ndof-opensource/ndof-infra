// Copyright 2026 The ndof Authors
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <string_view>

namespace ndof::__PROJECT_IDENT__ {

/// Name of this library as published (e.g. "ndof-__PROJECT_NAME__").
[[nodiscard]] std::string_view library_name() noexcept;

/// Semantic version of this library (e.g. "0.1.0").
[[nodiscard]] std::string_view library_version() noexcept;

} // namespace ndof::__PROJECT_IDENT__
