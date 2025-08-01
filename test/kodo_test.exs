defmodule KodoTest do
  use ExUnit.Case
  doctest Kodo

  test "greets the world" do
    assert Kodo.hello() == :world
  end
end
