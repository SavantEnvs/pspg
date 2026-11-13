#include "table_common.h"

/* selftest_table <file> <utf8: 0|1>: prints what pspg's table parser derives from the file. */
int
main(int argc, char **argv)
{
	FILE   *in;
	int		rc;

	if (argc != 3)
		return 2;

	in = fopen(argv[1], "r");
	if (!in)
		return 2;

	rc = pspg_table_parse(in, argv[2][0] == '1', stdout);

	fclose(in);
	return rc == 0 ? 0 : 1;
}
