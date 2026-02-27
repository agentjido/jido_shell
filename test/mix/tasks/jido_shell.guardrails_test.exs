defmodule Mix.Tasks.JidoShell.GuardrailsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("jido_shell.guardrails")
    :ok
  end

  test "succeeds for current repository" do
    output =
      capture_io(fn ->
        assert :ok = Mix.Tasks.JidoShell.Guardrails.run(["--root", File.cwd!()])
      end)

    assert output =~ "jido_shell guardrails: ok"
  end

  test "raises with formatted violations when guardrails fail" do
    with_tmp_dir(fn root ->
      legacy_file = Path.join(root, "lib/kodo/transport/term_ui.ex")
      File.mkdir_p!(Path.dirname(legacy_file))
      File.write!(legacy_file, "defmodule Kodo.Transport.TermUI do\nend\n")

      assert_raise Mix.Error, ~r/jido_shell guardrails failed/, fn ->
        Mix.Tasks.JidoShell.Guardrails.run(["--root", root])
      end
    end)
  end

  defp with_tmp_dir(fun) do
    root = Path.join(System.tmp_dir!(), "jido-shell-mix-guardrails-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
