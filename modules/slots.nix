# tart.runnerSlots / tart.runnerStateDir — the host-wide concurrent-VM budget
# shared by BOTH CI lanes (github-runner.nix's controllers and
# gitlab-runner.nix's custom executor). Options only; each lane's module
# imports this file and the module system dedupes the shared path, so a
# consumer may list either lane or both.
{ lib, ... }:
{
  options.tart = {
    runnerSlots = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Host-wide concurrent-VM ceiling shared by ALL CI VM lanes.";
    };
    runnerStateDir = lib.mkOption {
      type = lib.types.str;
      default = "/tmp/tart-runner";
      description = "Slots + host-key pins. /tmp survives the GUI session fine; pins regenerate via setup.";
    };
  };
}
