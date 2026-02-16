defmodule Mix.Tasks.JidoShell.InstallDocsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.JidoShell.Install.Docs

  test "short_doc/0 returns install summary" do
    assert Docs.short_doc() =~ "Install and configure Jido Shell"
  end

  test "long_doc/0 renders example content with command" do
    assert Docs.long_doc() =~ Docs.short_doc()
    assert Docs.long_doc() =~ Docs.example()
  end
end
