#!/usr/bin/perl
# Rewrite the names this project invented for itself: `pi*` -> `wei*`.
#
# Usage:  git ls-files -z | xargs -0 perl subst.pl
#
# Ordered substitutions, applied one file at a time. Order matters twice over:
#   - longer/more specific tokens before the prefixes that contain them
#     (`WeiApp` before `WeiShell`, `WEI_SHELL_C_H` before `WEI_`);
#   - the module path before the bare repository name, so
#     `lindividual/wei` becomes `lindividual/wei` and the leftover
#     `wei` (the README title, the mockups) becomes plain `wei`.
#
# NOT here, because they point at the upstream project rather than at us:
#   ~/.pi/agent/...        pi's credential store, skills and model catalogue
#   @earendil-works/pi-*   the oracle the fixture generators import
#   "pi's rule", "from pi" comments recording where a number was copied from
use strict;
use warnings;

my @subs = (
  # the MoonBit module path
  [ 'lindividual/wei', 'lindividual/wei' ],

  # environment variables
  [ 'WEI_SHELL_C_H',             'WEI_SHELL_C_H' ],
  [ 'WEI_',                'WEI_' ],

  # C symbols on the host boundary (MoonBit `extern`, the C, the Swift bindings)
  [ 'wei_',                'wei_' ],
  [ 'wei_run',                   'wei_run' ],

  # the static archive, and the linker settings that name it
  [ 'libwei',                 'libwei' ],
  [ 'linkWei',                'linkWei' ],

  # Swift package, targets and types
  [ 'wei-cli',             'wei-cli' ],
  [ 'WeiApp',               'WeiApp' ],
  [ 'WeiShell',                  'WeiShell' ],
  [ 'WeiModel',                  'WeiModel' ],
  [ 'WeiKit',                    'WeiKit' ],
  [ 'ShellClient',                 'ShellClient' ],
  [ 'ShellEvent',                  'ShellEvent' ],

  # the repository's own name, in prose and mockups
  [ 'wei',             'wei' ],

  # the state directory
  [ '.wei',                   '.wei' ],

  # run-time strings
  [ 'wei-agent',                 'wei-agent' ],
  [ 'wei-pasted',                'wei-pasted' ],
  [ 'wei-wire.log',              'wei-wire.log' ],
  [ 'wei-ws',                    'wei-ws' ],

  # identifiers named after what they read rather than what they are
  [ 'upstream_tool_fixtures',         'upstream_tool_fixtures' ],
  [ 'upstream_api_key',               'upstream_api_key' ],
  [ 'upstream_name',                  'upstream_name' ],
  [ 'upstream_key',                   'upstream_key' ],
  [ 'UPSTREAM_AI',                    'UPSTREAM_AI' ],
);

my $changed = 0;
for my $f (@ARGV) {
  next if -l $f;        # never write through a symlink: README.md is one
  next unless -T $f;    # text only, so the logo survives
  open my $in, '<', $f or die "$f: $!\n";
  local $/;
  my $text = <$in>;
  close $in;
  my $before = $text;
  for my $s (@subs) {
    my ($pat, $rep) = @$s;
    $text =~ s/\Q$pat\E/$rep/g;
  }
  next if $text eq $before;
  open my $out, '>', $f or die "$f: $!\n";
  print $out $text;
  close $out;
  $changed++;
}
warn "rewrote $changed files\n";
