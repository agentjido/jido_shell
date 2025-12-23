defmodule KodoTest do
  use Kodo.Case, async: true

  describe "version/0" do
    test "returns the application version" do
      version = Kodo.version()
      assert is_binary(version)
      assert version =~ ~r/^\d+\.\d+\.\d+/
    end
  end
end
