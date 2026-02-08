defmodule JidoShellTest do
  use Jido.Shell.Case, async: true

  describe "version/0" do
    test "returns the application version" do
      version = Jido.Shell.version()
      assert is_binary(version)
      assert version =~ ~r/^\d+\.\d+\.\d+/
    end
  end
end
