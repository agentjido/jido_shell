defmodule Jido.Shell.GuardrailsTest do
  use ExUnit.Case, async: true

  alias Jido.Shell.Guardrails

  test "check/1 passes for the current project layout" do
    assert :ok = Guardrails.check(File.cwd!())
  end

  test "check/1 detects collapsed Jido namespace modules in lib files" do
    root = new_temp_project_root("collapsed_namespace")
    on_exit(fn -> File.rm_rf(root) end)

    write_file(root, "lib/jido_shell.ex", "defmodule Jido.Shell do\nend\n")
    write_file(root, "lib/jido_shell/bad.ex", "defmodule JidoShell.Bad do\nend\n")

    assert {:error, violations} = Guardrails.check(root)

    assert Enum.any?(violations, fn
             {:collapsed_namespace_module, %{module: "JidoShell.Bad"}} -> true
             _ -> false
           end)
  end

  test "check/1 detects legacy lib/jido/shell layout files" do
    root = new_temp_project_root("legacy_layout")
    on_exit(fn -> File.rm_rf(root) end)

    write_file(root, "lib/jido_shell.ex", "defmodule Jido.Shell do\nend\n")
    write_file(root, "lib/jido/shell/legacy.ex", "defmodule Jido.Shell.Legacy do\nend\n")

    assert {:error, violations} = Guardrails.check(root)

    assert Enum.any?(violations, fn
             {:legacy_layout_path, %{path: "lib/jido/shell/legacy.ex"}} -> true
             _ -> false
           end)
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
