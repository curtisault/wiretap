defmodule WiretapTest do
  use ExUnit.Case
  doctest Wiretap

  test "greets the world" do
    assert Wiretap.hello() == :world
  end
end
