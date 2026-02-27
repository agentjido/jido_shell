defmodule Mix.Tasks.JidoShell.GuardrailsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("jido_shell.guardrails")
    :ok
  end

  test "passes for the current project state" do
    output =
      capture_io(fn ->
        assert :ok = Mix.Tasks.JidoShell.Guardrails.run(["--root", File.cwd!()])
      end)

    assert output =~ "jido_shell guardrails: ok"
  end

  test "raises for violated guardrails when checking a custom root" do
    root = new_temp_project_root("mix_guardrails_failure")
    on_exit(fn -> File.rm_rf(root) end)

    write_file(root, "lib/jido/shell/legacy.ex", "defmodule Jido.Shell.Legacy do\nend\n")

    assert_raise Mix.Error, ~r/Jido.Shell guardrails failed/, fn ->
      Mix.Tasks.JidoShell.Guardrails.run(["--root", root])
    end
  end

  defp new_temp_project_root(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "jido_shell_guardrails_#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp write_file(root, relative_path, body) do
    absolute_path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(absolute_path))
    File.write!(absolute_path, body)
  end
end
