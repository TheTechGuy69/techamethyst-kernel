// SPDX-License-Identifier: GPL-2.0
/* TechAmethyst status node: /sys/kernel/techamethyst/{version,features} */
#include <linux/init.h>
#include <linux/kobject.h>
#include <linux/sysfs.h>

static ssize_t version_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
	return sysfs_emit(buf, "%s\n", "TechAmethyst v1.1");
}

static ssize_t features_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
	return sysfs_emit(buf, "%s\n", "ksu=1 susfs=1 bbr=1 ntfs3=1 wlblock=1 tune=1");
}

static struct kobj_attribute ta_version_attr = __ATTR_RO(version);
static struct kobj_attribute ta_features_attr = __ATTR_RO(features);

static struct attribute *ta_attrs[] = {
	&ta_version_attr.attr,
	&ta_features_attr.attr,
	NULL,
};

static const struct attribute_group ta_group = {
	.attrs = ta_attrs,
};

static int __init techamethyst_init(void)
{
	struct kobject *kobj = kobject_create_and_add("techamethyst", kernel_kobj);

	if (!kobj)
		return -ENOMEM;
	return sysfs_create_group(kobj, &ta_group);
}
late_initcall(techamethyst_init);
