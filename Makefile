# Build the tool:            make
# Sign the tool and profile: make sign SIGN_ID="Apple Development: Your Name (TEAMID)"
# List your signing names:   security find-identity -v -p codesigning

TOOL    = remove-ai-models
PROFILE = no-ai-profile.mobileconfig
SIGNED  = no-ai-profile-signed.mobileconfig

all: $(TOOL)

$(TOOL): remove-ai-models.m
	clang -fobjc-arc -O2 -framework Foundation $< -o $@

sign: $(TOOL)
	@test -n "$(SIGN_ID)" || { echo 'Set SIGN_ID, e.g. make sign SIGN_ID="Apple Development: Your Name (TEAMID)"'; exit 1; }
	codesign --force -s "$(SIGN_ID)" $(TOOL)
	security cms -S -N "$(SIGN_ID)" -i $(PROFILE) -o $(SIGNED)

clean:
	rm -f $(TOOL) $(SIGNED)

.PHONY: all sign clean
