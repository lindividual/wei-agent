# Ordered substitutions, applied one file at a time by rename-to-wei.sh.
#
# Order matters twice over:
#   - longer/more specific tokens before the prefixes that contain them
#     (`PiShellApp` before `PiShell`, `PI_SHELL_C_H` before `PI_SHELL_`);
#   - the module path before the bare repo name, so `lindividual/pi-web-shell`
#     becomes `lindividual/wei` and the leftover `pi-web-shell` (the README title,
#     mockups) becomes plain `wei`.

my @subs = (
  # the MoonBit module path
  [ 'lindividual/pi-web-shell', 'lindividual/wei' ],

  # environment variables
  [ 'PI_SHELL_C_H',             'WEI_SHELL_C_H' ],
  [ 'PI_SHELL_',                'WEI_' ],

  # C symbols on the host boundary (MoonBit `extern`, the C, the Swift bindings)
  [ 'pi_shell_',                'wei_' ],
  [ 'pi_run',                   'wei_run' ],

  # the static archive, and the linker settings that name it
  [ 'libpiweb',                 'libwei' ],
  [ 'linkPiWeb',                'linkWei' ],

  # Swift package, targets and types
  [ 'pi-shell-cli',             'wei-cli' ],
  [ 'PiShellApp',               'WeiApp' ],
  [ 'PiShell',                  'WeiShell' ],
  [ 'PiModel',                  'WeiModel' ],
  [ 'PiKit',                    'WeiKit' ],
  [ 'PiClient',                 'ShellClient' ],
  [ 'PiEvent',                  'ShellEvent' ],

  # the repository's own name, in prose and mockups
  [ 'pi-web-shell',             'wei' ],

  # the state directory
  [ '.pi-mb',                   '.wei' ],

  # run-time strings
  [ 'pi-agent',                 'wei-agent' ],
  [ 'pi-pasted',                'wei-pasted' ],
  [ 'pi-wire.log',              'wei-wire.log' ],
  [ 'pi-ws',                    'wei-ws' ],

  # identifiers that were named after what they read, not what they are
  [ 'pi_tool_fixtures',         'upstream_tool_fixtures' ],
  [ 'pi_api_key',               'upstream_api_key' ],
  [ 'pi_name',                  'upstream_name' ],
  [ 'pi_key',                   'upstream_key' ],
  [ 'PI_AI',                    'UPSTREAM_AI' ],
);

while (<>) {
  for my $s (@subs) {
    my ($pat, $rep) = @$s;
    s/\Q$pat\E/$rep/g;
  }
  print;
}
