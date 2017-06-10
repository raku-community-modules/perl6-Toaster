use RakudoPrereq v2017.05.380.*,
    'Toaster.pm6 module requires Rakudo v2017.06 or newer';

unit class Toaster;

use Proc::Q;
use JSON::Fast;
use Temp::Path;
use Terminal::ANSIColor;
use WhereList;
use WWW;

use Toaster::DB;

has $.db = Toaster::DB.new;

constant INSTALL_TIMEOUT  = 10*60;
constant ECO_API          = 'https://modules.perl6.org/.json';
constant RAKUDO_REPO      = 'https://github.com/rakudo/rakudo';
constant ZEF_REPO         = 'https://github.com/ugexe/zef';
constant RAKUDO_BUILD_DIR = 'build'.IO.mkdir.self;
constant BANNED_MODULES   = (); # regex objects to regex over the name

my $batch = floor 1.3 * do with run 'lscpu', :out, :!err {
    .out.lines(:close).grep(*.contains: 'CPU(s)').head andthen .words.tail.Int
} || 8;


method toast-all ($commit = 'nom') {
    my @modules = jget(ECO_API)<dists>.map(*.<name>).sort
        .grep: *.match: BANNED_MODULES.none;
    say "About to toast {+@modules} modules";
    self.toast: @modules, $commit;
}
method toast (@modules, $commit = 'nom') {
    temp %*ENV;
    %*ENV<PATH> = self.build-rakudo: $commit;
    say "Toasting with path %*ENV<PATH>";
    my $store = make-temp-dir;
    my $ver = shell(:out, :!err,
      ｢perl6 -e 'print $*PERL.compiler.version.Str'｣).out.slurp: :close;
    say "Toasting with version $ver";
    run <zef info Test>; # output some info that zef uses right perl6
    my $rakudo      = $ver.subst(:th(2..*), '.', '').split('g').tail;
    my $rakudo-long
    = $ver.subst(:th(2, 3), '.', '-').subst(:th(2..*), '.', '');

    react whenever proc-q @modules.map({
        my $where = $store.add(.subst: :g, /\W/, '_').mkdir;
        «zef --debug install "$_" "-to=inst#$where"»
    }), :tags[@modules], :$batch, :timeout(INSTALL_TIMEOUT) {
        my ToastStatus $status = .killed
          ?? Kill !! .out.contains('FAIL') ?? Fail
            !! .exitcode == 0 ?? Succ !! Unkn;

        $!db.add: $rakudo, $rakudo-long,
            .tag, .err, .out, ~.exitcode, $status;
        say colored "Finished {.tag}: $status",
            <red green>[$status ~~ Succ];
    }
}

method build-rakudo (Str:D $commit = 'nom') {
    say "Starting to build rakudo $commit";
    indir RAKUDO_BUILD_DIR, {
        my $com-dir = $commit.subst: :g, /\W/, '_';
        $ = run «rm -fr "$com-dir"»;
        run «git clone "{RAKUDO_REPO}" "$com-dir"»;
        indir $*CWD.add($com-dir), {
            run «git checkout "$commit"»;
            say "Checkout done";
            run «perl Configure.pl --gen-moar --gen-nqp --backends=moar»;
            run «make»;
            run «make install»;
            run «git clone "{ZEF_REPO}"»;

            temp %*ENV;
            %*ENV<PATH> = $*CWD.add('install/bin').absolute ~ ":%*ENV<PATH>";
            indir $*CWD.add('zef'), { run «perl6 -Ilib bin/zef install . » }
            $*ENV<PATH> = $*CWD.add('install/share/perl6/site/bin')
              .absolute ~ ":%*ENV<PATH>";

            # Turn off auto update for p6c
            run «zef update»;
            given run(«zef --help», :err).err.slurp(:close)
              .lines.grep(*.starts-with: 'CONFIGURATION')
              .head.words.tail.trim.IO
            {
                my $j = from-json .slurp;
                for |$j<Repository> {
                    next unless .<short-name> eq 'p6c';
                    .<options><auto-update> = 0;
                    last;
                }
                .spurt: to-json $j;
            }

            $*ENV<PATH>
        }
    }
}
