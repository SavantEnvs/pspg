/* Drives pspg's tabular-text pipeline (readfile -> translate_headline -> finalize_tabular_data)
 * without a terminal. pspg.c is included whole so its static helpers are reachable. */
#include <stdio.h>
#include <string.h>

#define main pspg_main
#include "../src/pspg.c"
#undef main

static int
pspg_table_parse(FILE *in, bool utf8, FILE *report)
{
	Options		opts;
	DataDesc	desc;
	StateData	state;
	bool		ok;

	memset(&opts, 0, sizeof(opts));
	memset(&desc, 0, sizeof(desc));
	memset(&state, 0, sizeof(state));

	use_utf8 = utf8;
	current_state = &state;
	f_data = in;

	ok = readfile(&opts, &desc, &state);
	if (ok)
	{
		if (desc.headline)
			(void) translate_headline(&desc);

		if (desc.headline_transl)
			finalize_tabular_data(&desc);

		trim_footer_rows(&desc);

		if (report)
		{
			fprintf(report, "columns=%d border=%d linestyle=%c expanded=%d\n",
					desc.columns, desc.border_type, desc.linestyle,
					(int) desc.is_expanded_mode);
			fprintf(report, "first_data_row=%d last_data_row=%d footer_row=%d last_row=%d total_rows=%d\n",
					desc.first_data_row, desc.last_data_row, desc.footer_row,
					desc.last_row, desc.total_rows);
			fprintf(report, "headline_transl=%s\n",
					desc.headline_transl ? desc.headline_transl : "(none)");
		}

		if (desc.headline_transl)
			multilines_detection(&desc);

		if (report)
			fprintf(report, "multilines=%d\n", (int) desc.has_multilines);

		lb_print_all_ddesc(&desc, report ? report : stderr);
	}

	DataDescFree(&desc);
	f_data = NULL;

	return ok ? 0 : -1;
}
