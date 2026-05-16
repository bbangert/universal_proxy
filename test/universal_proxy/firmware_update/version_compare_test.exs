defmodule UniversalProxy.FirmwareUpdate.VersionCompareTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.FirmwareUpdate.VersionCompare

  describe "compare/2 — both sides valid semver" do
    test "release newer than current → :gt" do
      assert VersionCompare.compare("0.4.0", "0.3.0") == :gt
      assert VersionCompare.compare("v0.4.0", "0.3.0") == :gt
      assert VersionCompare.compare("0.4.0", "v0.3.0") == :gt
      assert VersionCompare.compare("1.0.0", "0.99.99") == :gt
      assert VersionCompare.compare("0.3.1", "0.3.0") == :gt
    end

    test "release older than current → :lt (regression: was :gt under string-inequality)" do
      # The original foot-gun: device 0.3.0, release tag v0.2.1 — string
      # inequality used to flag this as an available update (and a downgrade
      # disguised as one).
      assert VersionCompare.compare("0.2.1", "0.3.0") == :lt
      assert VersionCompare.compare("v0.2.1", "0.3.0") == :lt
      assert VersionCompare.compare("v0.1.0", "0.3.0") == :lt
      assert VersionCompare.compare("0.3.0", "0.3.1") == :lt
    end

    test "equal versions → :eq" do
      assert VersionCompare.compare("0.3.0", "0.3.0") == :eq
      assert VersionCompare.compare("v0.3.0", "0.3.0") == :eq
      assert VersionCompare.compare("0.3.0", "v0.3.0") == :eq
    end

    test "pre-release versions follow semver ordering (0.3.0 > 0.3.0-rc1)" do
      assert VersionCompare.compare("0.3.0-rc1", "0.3.0") == :lt
      assert VersionCompare.compare("0.3.0", "0.3.0-rc1") == :gt
    end
  end

  describe "compare/2 — non-semver inputs" do
    test "nil on either side → :missing" do
      assert VersionCompare.compare(nil, "0.3.0") == :missing
      assert VersionCompare.compare("0.3.0", nil) == :missing
      assert VersionCompare.compare(nil, nil) == :missing
    end

    test "non-parseable strings that match byte-for-byte → :eq" do
      assert VersionCompare.compare("nightly-abc", "nightly-abc") == :eq
      assert VersionCompare.compare("v-nightly", "-nightly") == :eq
    end

    test "non-parseable strings that differ → :incomparable" do
      assert VersionCompare.compare("nightly-abc", "nightly-def") == :incomparable
    end

    test "one side parseable, other not → :incomparable" do
      assert VersionCompare.compare("nightly-abc", "0.3.0") == :incomparable
      assert VersionCompare.compare("0.3.0", "nightly-abc") == :incomparable
    end
  end

  describe "update_available?/2 (boolean wrapper)" do
    test "newer release → true" do
      assert VersionCompare.update_available?("0.4.0", "0.3.0")
    end

    test "older release → false (the bug this module exists to prevent)" do
      refute VersionCompare.update_available?("0.2.1", "0.3.0")
      refute VersionCompare.update_available?("v0.1.0", "0.3.0")
    end

    test "equal → false" do
      refute VersionCompare.update_available?("0.3.0", "0.3.0")
    end

    test "incomparable falls back to 'show the option' (true)" do
      # Better to offer an update we're unsure about than to hide one;
      # mirrors pre-semver string-inequality behavior for non-parseable
      # tags.
      assert VersionCompare.update_available?("nightly-abc", "nightly-def")
      assert VersionCompare.update_available?("nightly-abc", "0.3.0")
    end

    test "nil release → false" do
      refute VersionCompare.update_available?(nil, "0.3.0")
    end
  end

  describe "up_to_date?/2 (boolean wrapper)" do
    test "equal → true" do
      assert VersionCompare.up_to_date?("0.3.0", "0.3.0")
    end

    test "device ahead of release → true (no separate 'ahead' state)" do
      assert VersionCompare.up_to_date?("0.2.1", "0.3.0")
      assert VersionCompare.up_to_date?("v0.1.0", "0.3.0")
    end

    test "device behind release → false" do
      refute VersionCompare.up_to_date?("0.4.0", "0.3.0")
    end

    test "non-parseable but equal → true" do
      assert VersionCompare.up_to_date?("nightly-abc", "nightly-abc")
    end

    test "incomparable → false" do
      refute VersionCompare.up_to_date?("nightly-abc", "nightly-def")
      refute VersionCompare.up_to_date?(nil, "0.3.0")
    end
  end
end
