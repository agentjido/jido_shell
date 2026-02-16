defmodule Mix.Tasks.JidoShell.InstallTest do
  use ExUnit.Case, async: true
  import Igniter.Test

  test "correct notice is posted" do
    test_project()
    |> Igniter.compose_task("jido_shell.install", [])
    |> assert_has_notice("""
    Jido Shell has been installed !

    Checkout the quickstart guide:
    https://github.com/agentjido/jido_shell?tab=readme-ov-file#interactive-shell

    """)
  end
end
