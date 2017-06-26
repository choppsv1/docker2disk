UVERSION := 17.04
UBASENAME := base
DOCKTAG ?= kvm
BASEREPO :=
BASETAG := ubuntu-base
BASEIMAGE := $(BASEREPO)$(BASETAG):$(UVERSION)
BUILDARGS := --network host --build-arg UVERSION=$(UVERSION) --build-arg http_proxy=$(http_proxy) --build-arg https_proxy=$(https_proxy) $$(cat .nocache-$(WBASE))
SFILES := $(wildcard scripts/*.sh)
DISK := $(DOCKTAG).vdi

# --------
# Building
# --------

all: $(DISK)

FORCE:

clean:
	echo "--pull --no-cache" > .nocache-$(DOCKTAG)

.nocache-$(DOCKTAG):
	echo "--pull" > .nocache-$(DOCKTAG)

.check-$(DOCKTAG): FORCE
	docker tag $(BASETAG):$(UVERSION) $(BASETAG)
	touch --date="$$(docker inspect -f '{{ .Created }}' ${BASEIMAGE})" $@ || touch -t 19800101 $@

$(DISK): init .check-$(DOCKTAG) Dockerfile-$(DOCKTAG) docker2disk.sh $(SFILES) .nocache-$(DOCKTAG)
	docker build  $(BUILDARGS) -t $(DOCKTAG) -f Dockerfile-$(DOCKTAG) .
	echo -n > .nocache-$(DOCKTAG)
	./docker2disk.sh -F vdi -f $(DOCKTAG) $(DISK) 60G

ubuntu-base: base
base:
	curl -s 'http://cdimage.ubuntu.com/ubuntu-base/releases/$(UVERSION)/release/ubuntu-base-$(UVERSION)-$(UBASENAME)-amd64.tar.gz' | \
	    gzip -dc | docker import - $(BASEREPO)$(BASETAG):$(UVERSION)

# ------------------
# Testing and Triage
# ------------------

NBD := /dev/nbd8
MP := /mnt

undef:
	- virsh destroy kvm
	- virsh undefine kvm

test: undef
	sed -e "s,DISKPATH,$(shell pwd)/$(DISK)," < kvm.xml.in > kvm.xml
	virsh define kvm.xml
	virsh start kvm
	virsh console kvm

unmount:
	- sudo umount $(MP)
	- sudo qemu-nbd --disconnect $(NBD)

mount:
	sudo qemu-nbd --connect=$(NBD) $(DISK)
	sudo mount $(NBD)p1 $(MP)
