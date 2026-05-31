.PHONY: test lint clean

test:
	./test/test-prtend.sh

lint:
	shellcheck bin/prtend lib/prtend/*.bash lib/prtend/prtend-subcommands/*.bash test/*.sh

clean:
	rm -rf .test-tmp result result-*
