#include <stdint.h>
#include <stdlib.h>
#include "table_common.h"

/* First byte selects UTF-8 handling; the rest is the table text. */
int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	FILE   *in;
	FILE   *sink;
	char   *copy;
	char   *sinkbuf = NULL;
	size_t	sinksize = 0;
	int		rc;

	if (size < 2)
		return -1;

	copy = malloc(size - 1);
	if (!copy)
		return -1;
	memcpy(copy, data + 1, size - 1);

	in = fmemopen(copy, size - 1, "r");
	if (!in)
	{
		free(copy);
		return -1;
	}

	sink = open_memstream(&sinkbuf, &sinksize);
	if (!sink)
	{
		fclose(in);
		free(copy);
		return -1;
	}

	rc = pspg_table_parse(in, (data[0] & 1) != 0, sink);

	fclose(sink);
	free(sinkbuf);
	fclose(in);
	free(copy);

	return rc;
}
