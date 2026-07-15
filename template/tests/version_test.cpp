// Copyright 2026 The ndof Authors
// SPDX-License-Identifier: Apache-2.0

#include "ndof/__PROJECT_IDENT__/version.hpp"

#include <gtest/gtest.h>

namespace {

TEST(Version, LibraryNameMatchesPackage) {
    EXPECT_EQ(ndof::__PROJECT_IDENT__::library_name(), "ndof-__PROJECT_NAME__");
}

TEST(Version, LibraryVersionIsNonEmpty) {
    EXPECT_FALSE(ndof::__PROJECT_IDENT__::library_version().empty());
}

} // namespace
